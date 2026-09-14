@echo off
:: Mazda CMU CarPlay-HUD toolkit — Windows (needs built-in OpenSSH: ssh.exe/scp.exe from Win 10 build 1803+)
setlocal EnableDelayedExpansion
set "DIR=%~dp0"
set "FILES=%DIR%files"
set "KEY=%DIR%id_rsa_cmu"
set "CMU=cmu@192.168.53.1"
set "PORT=36000"
set "SSHOPTS=-i "%KEY%" -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15"

:: md5 sanity (expected values of shipped payloads)
set "MD5_SO_PURE=0ce29da4f16f72b0b8f931bee88ff332"
set "MD5_SO_MOD=faf82efb028c6af9898122a5ff5833be"

where ssh >nul 2>&1 || (echo ERROR: ssh.exe not found. Windows 10 build 1803+ needed, or install OpenSSH via Optional Features. & pause & exit /b 1)
if not exist "%KEY%" (echo SSH key missing: %KEY% & pause & exit /b 1)

icacls "%KEY%" /inheritance:r /grant:r "%USERNAME%":R >nul 2>&1

:menu
echo.
echo === Mazda CMU CarPlay-HUD toolkit ===
echo.
echo   1  Create USB unlock stick (root-access XSS payload)
echo   2  Backup CMU state (before mods)
echo   3  Install PURE KidMixer Patch   (contains known speed limit issue)
echo   4  Install ilshyma HUD Patch     (* speed limit fixed)
echo   5  Full rollback (restore stock)
echo   L  Live tail speed-daemon log (mod only)
echo   9  Check SSH connection
echo   0  Exit
echo.
set "C="
set /p "C=> "

if /I "%C%"=="1" goto usb
if /I "%C%"=="2" goto backup
if /I "%C%"=="3" goto install_pure
if /I "%C%"=="4" goto install_mod
if /I "%C%"=="5" goto rollback
if /I "%C%"=="L" goto tail_log
if /I "%C%"=="9" goto check
if /I "%C%"=="0" exit /b 0
if "%C%"=="" goto menu
echo invalid.
goto menu

:check
echo. & echo === SSH check ===
ping -n 3 -w 1000 192.168.53.1 >nul || (echo CMU not reachable. Insert USB and tap SSH in XSS menu on CMU. & goto menu)
ssh %SSHOPTS% -p %PORT% %CMU% "uname -a && uptime" || echo SSH failed
goto menu

:check_conn
ping -n 2 -w 1000 192.168.53.1 >nul || (echo CMU not reachable — insert USB and tap SSH in XSS menu. & exit /b 1)
ssh %SSHOPTS% -p %PORT% %CMU% "true" >nul 2>&1 || (echo SSH failed — retry via USB / XSS. & exit /b 1)
exit /b 0

:: ===============================================================
:: 1) Create USB unlock stick — number-picker of removable drives
:: ===============================================================
:usb
echo. & echo === Create USB unlock stick ===
echo detecting removable drives...
echo.
set /a N=0
for /f "usebackq tokens=1,2,3 delims=|" %%a in (`powershell -NoProfile -Command "Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' ^| ForEach-Object { '{0}|{1}|{2:N1} GB' -f $_.DeviceID, ($_.VolumeName -as [string]), ($_.Size/1GB) }"`) do (
  set /a N+=1
  set "DRIVE_!N!=%%a"
  set "LABEL_!N!=%%b"
  set "SIZE_!N!=%%c"
  if "%%b"=="" (
    echo   !N!  %%a  ^(%%c^)
  ) else (
    echo   !N!  %%a  ^(%%b, %%c^)
  )
)
if !N!==0 (
  echo no removable drive found. Plug one in and pick option 1 again.
  goto menu
)
echo   0  cancel
echo.
set "CH="
set /p "CH=> "
if "!CH!"=="" goto menu
if "!CH!"=="0" goto menu
set "TARGET=!DRIVE_%CH%!"
if "!TARGET!"=="" (echo invalid choice & goto menu)
if not exist "!TARGET!\" (echo drive not accessible & goto menu)

echo.
echo Before continuing, format !TARGET! as FAT32 with label MZD:
echo   Explorer -^> right-click !TARGET! -^> Format... -^> FAT32, label MZD, Quick -^> OK
echo.
set "OK="
set /p "OK=formatted and ready? [y/N] > "
if /I not "!OK!"=="y" (echo cancelled & goto menu)

echo copying MP3-XSS payload to !TARGET!\ ...
xcopy /E /I /Y "%FILES%\usb_unlock\*" "!TARGET!\" >nul || (echo copy failed & goto menu)
echo done. Safely eject and take to the car.
echo In CMU: Media -^> USB -^> tap any mp3 -^> tap SSH in the XSS menu.
goto menu

:: ===============================================================
:: 2) Backup CMU state
:: ===============================================================
:backup
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Backup CMU ===
for /f "tokens=2 delims==" %%a in ('wmic os get localdatetime /value ^| find "="') do set "TS=%%a"
set "TS=!TS:~0,8!_!TS:~8,6!"
set "DST=%DIR%backups\!TS!"
mkdir "!DST!" 2>nul
ssh %SSHOPTS% -p %PORT% %CMU% "tar -czf /tmp/backup.tar.gz /jci/sm/sm.conf /jci/sm/sm_WCP.conf /etc/devmgr_config_master.xml /jci/carplay/blmjcicarplay.so /jci/version.ini /data_persist/cp-hud-mod /data_persist/splim_udpd_start.sh /data_persist/splim 2>/dev/null; ls -la /tmp/backup.tar.gz"
scp %SSHOPTS% -P %PORT% %CMU%:/tmp/backup.tar.gz "!DST!\backup.tar.gz"
ssh %SSHOPTS% -p %PORT% %CMU% "rm -f /tmp/backup.tar.gz"
echo backup saved: !DST!\backup.tar.gz
goto menu

:: ===============================================================
:: 3) Install PURE KidMixer Patch (contains known speed-limit issue)
:: ===============================================================
:install_pure
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Install PURE KidMixer Patch (known speed-limit issue) ===

:: base install (KidMixer's own install.sh — LD_PRELOAD, NaviSupported=TRUE)
ssh %SSHOPTS% -p %PORT% %CMU% "mkdir -p /tmp/cp-hud-install"
scp %SSHOPTS% -P %PORT% "%FILES%\install.sh" %CMU%:/tmp/cp-hud-install/
scp %SSHOPTS% -P %PORT% "%FILES%\libpatch-blmjcicarplay.so" %CMU%:/tmp/cp-hud-install/
ssh %SSHOPTS% -p %PORT% %CMU% "cd /tmp/cp-hud-install && sh install.sh"

:: force pure .so (overlay in case mod was on disk)
echo overlaying pure .so (in case a mod .so was on disk)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
scp %SSHOPTS% -P %PORT% "%FILES%\libpatch-blmjcicarplay.so" %CMU%:/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so
ssh %SSHOPTS% -p %PORT% %CMU% "chmod 0644 /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so && md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so && echo '(expected: %MD5_SO_PURE%)'"

:: wipe any prior speed-mod daemon + state
echo clearing any prior speed-mod daemon + state
ssh %SSHOPTS% -p %PORT% %CMU% "pkill -9 -f splim_bridge 2>/dev/null; pkill -9 -f splim_udpd 2>/dev/null; rm -f /data_persist/splim_udpd_start.sh /data_persist/cp-hud-mod/splim_bridge*.sh /data_persist/splim /mnt/data_persist/splim /tmp/splim_v*_cache /tmp/splim_v*_last; rm -rf /tmp/splim_v*_cache; sleep 1"

echo pure KidMixer installed. Rebooting (wait ~2 min then re-insert USB + tap SSH in XSS menu).
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot"
goto menu

:: ===============================================================
:: 4) Install ilshyma HUD Patch (speed limit fixed — v16 mod)
:: ===============================================================
:install_mod
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Install ilshyma HUD Patch (speed limit fixed) ===

:: KidMixer's own installer
ssh %SSHOPTS% -p %PORT% %CMU% "mkdir -p /tmp/cp-hud-install"
scp %SSHOPTS% -P %PORT% "%FILES%\install.sh" %CMU%:/tmp/cp-hud-install/
scp %SSHOPTS% -P %PORT% "%FILES%\libpatch-blmjcicarplay.so" %CMU%:/tmp/cp-hud-install/
ssh %SSHOPTS% -p %PORT% %CMU% "cd /tmp/cp-hud-install && sh install.sh"

:: overlay our patched .so (v16 — km/h fix + read_splim future-ts guard)
echo overlaying patched .so (v16)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
scp %SSHOPTS% -P %PORT% "%FILES%\libpatch-blmjcicarplay-splim.so" %CMU%:/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so
ssh %SSHOPTS% -p %PORT% %CMU% "chmod 0644 /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so && md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so && echo '(expected: %MD5_SO_MOD%)'"

:: deploy v16 speed-mirror daemon + auto-launcher
echo deploying speed-mirror daemon (v16) + auto-launcher
scp %SSHOPTS% -P %PORT% "%FILES%\splim_bridge.sh" %CMU%:/data_persist/cp-hud-mod/
scp %SSHOPTS% -P %PORT% "%FILES%\splim_udpd_start.sh" %CMU%:/data_persist/
ssh %SSHOPTS% -p %PORT% %CMU% "chmod +x /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/splim_udpd_start.sh"

echo ilshyma HUD Patch installed. Rebooting (wait ~2 min then re-insert USB + tap SSH in XSS menu).
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot"
goto menu

:: ===============================================================
:: 5) Full rollback
:: ===============================================================
:rollback
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Full rollback ===
echo 1) killing speed daemon + wiping state
ssh %SSHOPTS% -p %PORT% %CMU% "pkill -9 -f splim_bridge 2>/dev/null; pkill -9 -f splim_udpd 2>/dev/null; rm -f /data_persist/splim_udpd_start.sh /data_persist/cp-hud-mod/splim_bridge*.sh /data_persist/splim /mnt/data_persist/splim /tmp/splim_v*_cache /tmp/splim_v*_last; rm -rf /tmp/splim_v*_cache; sleep 1"

echo 2) running KidMixer uninstall.sh (restores sm.conf, NaviSupported=FALSE)
scp %SSHOPTS% -P %PORT% "%FILES%\uninstall.sh" %CMU%:/tmp/uninstall.sh
ssh %SSHOPTS% -p %PORT% %CMU% "sh /tmp/uninstall.sh"

echo 3) verifying + force-cleaning any residue
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null || true; for CONF in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do [ -f \"$CONF\" ] || continue; before=$(grep -c libpatch-blmjcicarplay \"$CONF\" 2>/dev/null || echo 0); if [ \"$before\" -gt 0 ]; then echo \"  ! $CONF still has $before LD_PRELOAD lines - force-stripping\"; grep -v libpatch-blmjcicarplay \"$CONF\" | grep -v 'LD_LIBRARY_PATH.*jci/lib:/usr/lib' > /tmp/rb.clean; cp /tmp/rb.clean \"$CONF\"; rm -f /tmp/rb.clean; sed -i '/name=\"jciCARPLAY\"/ s/reset_board=\"no\"/reset_board=\"yes\"/' \"$CONF\"; fi; done; if grep -q '<name>NaviSupported</name><value>TRUE</value>' /etc/devmgr_config_master.xml 2>/dev/null; then echo '  ! NaviSupported=TRUE - forcing to FALSE'; sed -i 's#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#' /etc/devmgr_config_master.xml; fi; rm -rf /data_persist/cp-hud-mod; sync; mount -o remount,ro / 2>/dev/null || true; echo \"  final: sm.conf preload=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null)  sm_WCP.conf preload=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null)  NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$')\""

echo rollback done. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot"
goto menu

:: ===============================================================
:: L) Live tail speed-daemon log (Ctrl+C to exit)
:: ===============================================================
:tail_log
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Live tail speed-daemon log (Ctrl+C to exit) ===
ssh %SSHOPTS% -p %PORT% %CMU% "ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1 | xargs -r tail -F 2>/dev/null"
goto menu
