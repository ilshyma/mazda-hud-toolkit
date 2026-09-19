@echo off
:: ============================================================================
::  Mazda CMU CarPlay-HUD toolkit — Windows 10/11
:: ============================================================================
::  Requires: OpenSSH Client (Win10 1803+ has it by default; on Win11 verify in
::  Settings > Optional Features), and PowerShell (bundled with every Windows).
::
::  MAIN FLOW (1..5) — do these once, in order:
::    1  Create USB unlock stick   — number-picker of removable drives
::    2  Backup CMU                — safety net before touching anything
::    3  Full rollback             — optional, force a clean starting point
::    4  Install ilshyma HUD Patch — retries + md5-verifies every file, reboots,
::                                     WAITS for SSH to come back, auto-validates
::    5  Validate installation     — re-run any time; auto-fixes the daemon
::
::  ADVANCED (P/X/D/F/T/C) — not needed for normal use:
::    P  Install PURE KidMixer Patch    (upstream, has speed-limit issue)
::    X  Install legacy pre-v16 mod .so (fallback if v16's read_splim guard fires wrongly)
::    D  Full diagnostic dump
::    F  Force-start the speed daemon
::    T  Live-tail the daemon log
::    C  CarPlay HUD arrow debug log
::
::  Sync-parity with the macOS/Linux toolkit.sh: same variants, same md5s, same
::  auto-validate-after-reboot flow. Same-day fixes applied here: no `pkill -f`
::  (self-kill), daemon deployed as splim_udpd (no .sh), .variant marker written,
::  stale splim wiped, deprecated WMIC replaced by PowerShell Get-Date, robust
::  ping/timestamp parsing, quoted key path for spaces in the folder name.
:: ============================================================================
setlocal EnableDelayedExpansion
set "DIR=%~dp0"
set "FILES=%DIR%files"
set "KEY=%DIR%id_rsa_cmu"
set "CMU=cmu@192.168.53.1"
set "PORT=36000"

:: NOTE: SSHOPTS purposely has NO surrounding double quotes on the `set` line
:: itself — those would end at the first inner quote around %KEY%, leaving
:: SSHOPTS truncated to just `-i "`, and every SSH call would silently ignore
:: our key + options. Every reference below writes `%SSHOPTS%` unquoted so the
:: inner quotes on the KEY path survive to ssh.exe.
:: ServerAliveInterval + KeepAlive: match the .sh side, prompts ssh.exe to
:: notice a dropped link quickly instead of hanging for minutes.
set SSHOPTS=-i "%KEY%" -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes

:: Expected md5 of shipped payloads (matched to files\)
set "MD5_SO_PURE=0ce29da4f16f72b0b8f931bee88ff332"
set "MD5_SO_MOD=faf82efb028c6af9898122a5ff5833be"
set "MD5_SO_MOD_LEGACY=c8800f0e743612543ecae705738c987e"
set "MD5_SPLIM_BRIDGE=0aa7119da7bbbdb25a3ab271e238ae44"
set "MD5_SPLIM_LAUNCHER=26cdb9e1a2333425e57923b334c5cc50"

:: Preflight — hard failures we can detect right now.
where ssh >nul 2>&1 || (echo ERROR: ssh.exe not found. & echo   Install "OpenSSH Client" via Settings ^> Apps ^> Optional Features. & pause & exit /b 1)
where scp >nul 2>&1 || (echo ERROR: scp.exe not found. & echo   Install "OpenSSH Client" via Settings ^> Apps ^> Optional Features. & pause & exit /b 1)
where powershell >nul 2>&1 || (echo ERROR: powershell.exe not found. This is highly unusual on Windows. & pause & exit /b 1)
if not exist "%KEY%" (echo ERROR: SSH key missing at %KEY% & echo   Re-download the toolkit ZIP, this file is required. & pause & exit /b 1)

:: Restrict key file perms so ssh.exe accepts it (Windows OpenSSH refuses
:: world-readable private keys). icacls silently is fine on already-restricted keys.
icacls "%KEY%" /inheritance:r /grant:r "%USERNAME%":R >nul 2>&1

:menu
echo.
echo ==========================================================
echo  Mazda CMU CarPlay-HUD toolkit
echo ==========================================================
echo.
echo   MAIN FLOW  ^-^-  do these once, in order
echo   ----------------------------------------
echo   1  Create USB unlock stick
echo   2  Backup CMU (factory state)
echo   3  Full rollback  (start clean ^-^- optional but recommended)
echo   4  Install ilshyma HUD Patch  * recommended
echo        auto-retries -^> waits for reboot -^> auto-validates
echo   5  Validate installation  (re-run any time)
echo.
echo   ADVANCED / TROUBLESHOOTING
echo   ----------------------------------------
echo   P  Install PURE KidMixer Patch  (no speed-limit fix)
echo   X  Install legacy pre-v16 mod .so  (speed-limit fallback)
echo   D  Full diagnostic dump
echo   F  Force-start speed daemon
echo   T  Live-tail speed-daemon log
echo   C  CarPlay HUD arrow debug log
echo.
echo   9  Check SSH connection
echo   0  Exit
echo.
set "C="
set /p "C=> "

if /I "%C%"=="1" goto usb
if /I "%C%"=="2" goto backup
if /I "%C%"=="3" goto rollback
if /I "%C%"=="4" goto install_mod
if /I "%C%"=="5" goto validate
if /I "%C%"=="P" goto install_pure
if /I "%C%"=="X" goto install_mod_legacy
if /I "%C%"=="D" goto diagnose
if /I "%C%"=="F" goto force_start_daemon
if /I "%C%"=="T" goto tail_log
if /I "%C%"=="C" goto carplay_log
if /I "%C%"=="9" goto check
if /I "%C%"=="0" exit /b 0
if "%C%"=="" goto menu
echo invalid.
goto menu

:: ===============================================================
:: SSH check (menu 9 + used before every SSH-requiring action)
:: ===============================================================
:check
echo. & echo === SSH check ===
:: Windows ping returns 0 even for "Destination host unreachable" replies —
:: only a TTL= line means an actual response from the target. Grep for it.
ping -n 3 -w 1000 192.168.53.1 | find "TTL=" >nul
if errorlevel 1 (echo CMU not reachable. Insert USB and tap SSH in XSS menu on CMU. & goto menu)
ssh %SSHOPTS% -p %PORT% %CMU% "uname -a && uptime"
if errorlevel 1 (echo SSH failed. & goto menu)
goto menu

:check_conn
:: Same as :check but as a CALLable sub-routine (returns via exit /b).
ping -n 2 -w 1000 192.168.53.1 | find "TTL=" >nul
if errorlevel 1 (echo CMU not reachable ^-^- insert USB and tap SSH in XSS menu on CMU. & exit /b 1)
ssh %SSHOPTS% -p %PORT% %CMU% "true" >nul 2>&1
if errorlevel 1 (echo SSH failed ^-^- retry via USB / XSS. & exit /b 1)
exit /b 0

:wait_for_ssh
:: Poll every 5s (up to 5min) for SSH to come back after a reboot. Prints
:: friendly guidance during the wait. Returns via exit /b (0 = back, 1 = timeout).
echo.
echo ! CMU is rebooting -- this takes about 90 seconds.
echo   In the car: once the screen comes back, Media -^> USB -^> tap any mp3
echo   (or let it autoplay) -^> tap SSH in the XSS menu.
echo   I'll detect the SSH connection automatically -- checking every 5s.
echo.
set /a WAIT_ELAPSED=0
:wait_for_ssh_loop
ping -n 2 -w 1000 192.168.53.1 | find "TTL=" >nul
if not errorlevel 1 (
  ssh %SSHOPTS% -p %PORT% %CMU% "true" >nul 2>&1
  if not errorlevel 1 (echo. & echo * SSH is back ^(after !WAIT_ELAPSED!s^) & exit /b 0)
)
set /a WAIT_ELAPSED+=5
if !WAIT_ELAPSED! GEQ 300 (echo. & echo ! SSH did not come back within 300s. Run option 5 ^(Validate^) manually when back. & exit /b 1)
<nul set /p "=." >nul
timeout /t 5 /nobreak >nul
goto wait_for_ssh_loop

:: ===============================================================
:: 1) Create USB unlock stick — number-picker of removable drives
:: ===============================================================
:usb
echo. & echo === Create USB unlock stick ===
echo detecting removable drives...
echo.
:: Enumerate removable drives via PowerShell -> temp file (avoids the CMD/PS
:: escape-hell of an inline for-loop backtick pipeline).
set "PSOUT=%TEMP%\mzd_disks.txt"
del /q "%PSOUT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' | ForEach-Object { $lbl = if ($_.VolumeName) { $_.VolumeName } else { '(no label)' }; '{0}|{1}|{2:N1} GB' -f $_.DeviceID, $lbl, ($_.Size/1GB) } | Out-File -Encoding ASCII '%PSOUT%'" 2>nul
if not exist "%PSOUT%" (
  echo PowerShell failed to enumerate drives.
  echo   Open cmd and try: powershell -Command "Get-CimInstance Win32_LogicalDisk"
  echo   If that also fails, PowerShell is disabled by group policy -- ask IT.
  pause
  goto menu
)
set /a N=0
for /f "usebackq tokens=1,2,3 delims=|" %%a in ("%PSOUT%") do (
  set /a N+=1
  set "DRIVE_!N!=%%a"
  set "LABEL_!N!=%%b"
  set "SIZE_!N!=%%c"
  echo   !N!  %%a  ^(%%b, %%c^)
)
del /q "%PSOUT%" 2>nul
if !N!==0 (echo no removable drive found. Plug one in and pick option 1 again. & goto menu)
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
echo   Explorer -^> right-click !TARGET! -^> Format...
echo     File system: FAT32   Volume label: MZD   Quick Format: ON  -^> Start
echo.
set "OK="
set /p "OK=formatted and ready? [y/N] > "
if /I not "!OK!"=="y" (echo cancelled & goto menu)

echo copying MP3-XSS payload to !TARGET!\ ...
xcopy /E /I /Y "%FILES%\usb_unlock\*" "!TARGET!\" >nul
if errorlevel 1 (echo copy failed & goto menu)

:: Also drop mp3s at the drive ROOT — some CMUs auto-play the first root-level
:: audio track on insert, which is what makes the XSS trigger without a manual tap.
xcopy /Y "%FILES%\usb_unlock\mp3\*.mp3" "!TARGET!\" >nul 2>nul

echo done. Safely eject and take to the car.
echo In CMU: Media -^> USB -^> tap any mp3 ^(or let it autoplay^) -^> tap SSH in the XSS menu.
goto menu

:: ===============================================================
:: 2) Backup CMU state
:: ===============================================================
:backup
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Backup CMU state ^(before any mods^) ===

:: Timestamp via PowerShell (WMIC is removed by default on Win 11 22000+).
for /f %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%a"
if "!TS!"=="" (echo could not get timestamp & goto menu)
set "DST=%DIR%backups\!TS!"
mkdir "!DST!" 2>nul
echo backing up to !DST!

ssh %SSHOPTS% -p %PORT% %CMU% "tar -czf /tmp/backup.tar.gz /jci/sm/sm.conf /jci/sm/sm_WCP.conf /etc/devmgr_config_master.xml /jci/carplay/blmjcicarplay.so /jci/version.ini /data_persist/cp-hud-mod /data_persist/splim_udpd_start.sh /data_persist/splim 2>/dev/null; ls -la /tmp/backup.tar.gz"
if errorlevel 1 (echo tar failed on CMU & goto menu)

scp %SSHOPTS% -P %PORT% %CMU%:/tmp/backup.tar.gz "!DST!\backup.tar.gz"
if errorlevel 1 (echo scp of backup failed & goto menu)

ssh %SSHOPTS% -p %PORT% %CMU% "rm -f /tmp/backup.tar.gz" >nul 2>&1

:: Verify local file is non-empty
for %%A in ("!DST!\backup.tar.gz") do set "SZ=%%~zA"
if "!SZ!"=="0" (echo backup file is empty ^-^- something went wrong & goto menu)
if "!SZ!"=="" (echo backup file missing after copy & goto menu)
echo * backup saved: !DST!\backup.tar.gz ^(!SZ! bytes^)
goto menu

:: ===============================================================
:: Helper: push_verify SRC DST EXPECTED_MD5
:: Copies SRC to CMU:DST, then verifies remote md5 == EXPECTED_MD5.
:: Retries up to 3 times. Sets errorlevel 1 on failure.
:: Args passed via env vars because CMD lacks proper function args.
:: ===============================================================
:push_verify
set /a PV_TRY=0
:push_verify_loop
set /a PV_TRY+=1
if "!PV_TRY!"=="1" (echo   -^> !PV_SRC! -^> !PV_DST!)
if !PV_TRY! GTR 1 echo     retry !PV_TRY!/3...
scp %SSHOPTS% -P %PORT% "!PV_SRC!" %CMU%:"!PV_DST!"
if not errorlevel 1 (
  set "PV_GOT="
  for /f "usebackq" %%a in (`ssh %SSHOPTS% -p %PORT% %CMU% "chmod 0644 '!PV_DST!' 2>/dev/null; md5sum '!PV_DST!' 2>/dev/null | awk '{print $1}'"`) do set "PV_GOT=%%a"
  if "!PV_GOT!"=="!PV_WANT!" (echo     * md5 verified ^(!PV_WANT!^) & exit /b 0)
  echo     md5 mismatch ^(got=!PV_GOT! want=!PV_WANT!^)
) else (
  echo     scp failed
)
if !PV_TRY! LSS 3 (timeout /t 2 /nobreak >nul & goto push_verify_loop)
echo   ! giving up on !PV_SRC! after 3 attempts
exit /b 1

:: ===============================================================
:: Helper: kidmixer_base — copies KidMixer install.sh + pure .so and runs it.
:: Idempotent on CMU side (skips lines already present). Retries 3x.
:: ===============================================================
:kidmixer_base
if not exist "%FILES%\install.sh"                (echo local file missing: install.sh                & exit /b 1)
if not exist "%FILES%\libpatch-blmjcicarplay.so" (echo local file missing: libpatch-blmjcicarplay.so & exit /b 1)
echo   copying KidMixer install.sh + pure .so
set /a KB_TRY=0
:kidmixer_base_loop
set /a KB_TRY+=1
if !KB_TRY! GTR 1 echo     retry !KB_TRY!/3...
ssh %SSHOPTS% -p %PORT% %CMU% "mkdir -p /tmp/cp-hud-install" && ^
scp %SSHOPTS% -P %PORT% "%FILES%\install.sh"                %CMU%:/tmp/cp-hud-install/ && ^
scp %SSHOPTS% -P %PORT% "%FILES%\libpatch-blmjcicarplay.so" %CMU%:/tmp/cp-hud-install/ && ^
ssh %SSHOPTS% -p %PORT% %CMU% "cd /tmp/cp-hud-install && sh install.sh"
if not errorlevel 1 exit /b 0
if !KB_TRY! LSS 3 (timeout /t 2 /nobreak >nul & goto kidmixer_base_loop)
echo   ! KidMixer base install failed after 3 attempts
exit /b 1

:: ===============================================================
:: Helper: wipe_speed_mod  --  kill our speed daemon + wipe its state on CMU
:: NEVER uses `pkill -f`: this very ssh command's cmdline CONTAINS the words
:: "splim_bridge"/"splim_udpd", so `pkill -f splim_bridge` would SIGKILL the
:: script that's running it, killing itself mid-line with zero output.
:: Plain pkill/pgrep match only the process's short "comm" name (splim_udpd
:: for the daemon, "sh" for this management script) — correct target, no
:: self-match. This is the exact same fix as toolkit.sh's wipe_speed_mod().
:: ===============================================================
:wipe_speed_mod
ssh %SSHOPTS% -p %PORT% %CMU% "pkill -9 splim_bridge 2>/dev/null; pkill -9 splim_udpd 2>/dev/null; kill -9 $(pgrep splim_udpd) 2>/dev/null; rm -f /data_persist/splim_udpd_start.sh /data_persist/cp-hud-mod/splim_bridge*.sh /data_persist/cp-hud-mod/splim_udpd /data_persist/cp-hud-mod/.variant /data_persist/splim /mnt/data_persist/splim /tmp/splim_v*_cache /tmp/splim_v*_last; rm -rf /tmp/splim_v*_cache; sleep 1; true" >nul 2>&1
exit /b 0

:: ===============================================================
:: 3) Full rollback  --  restore factory state
:: ===============================================================
:rollback
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Full rollback ^-^- restore factory state ===

echo 1/3 . killing our speed daemon + wiping state
call :wipe_speed_mod

echo 2/3 . running KidMixer uninstall.sh
scp %SSHOPTS% -P %PORT% "%FILES%\uninstall.sh" %CMU%:/tmp/uninstall.sh
if errorlevel 1 (echo scp uninstall.sh failed & goto menu)
ssh %SSHOPTS% -p %PORT% %CMU% "sh /tmp/uninstall.sh"

echo 3/3 . verifying + force-cleaning any residue
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null || true; for CONF in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do [ -f \"$CONF\" ] || continue; before=$(grep -c libpatch-blmjcicarplay \"$CONF\" 2>/dev/null); before=${before:-0}; if [ \"$before\" -gt 0 ]; then echo \"  ! $CONF still has $before LD_PRELOAD lines - force-stripping\"; grep -v libpatch-blmjcicarplay \"$CONF\" | grep -v 'LD_LIBRARY_PATH.*jci/lib:/usr/lib' > /tmp/rb.clean; cp /tmp/rb.clean \"$CONF\"; rm -f /tmp/rb.clean; sed -i '/name=\"jciCARPLAY\"/ s/reset_board=\"no\"/reset_board=\"yes\"/' \"$CONF\"; fi; done; if grep -q '<name>NaviSupported</name><value>TRUE</value>' /etc/devmgr_config_master.xml 2>/dev/null; then echo '  ! NaviSupported=TRUE - forcing to FALSE'; sed -i 's#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#' /etc/devmgr_config_master.xml; fi; rm -rf /data_persist/cp-hud-mod; sync; mount -o remount,ro / 2>/dev/null || true; echo \"  final: sm.conf preload=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null)  sm_WCP.conf preload=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null)  NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$')\""

echo * rollback commands complete. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 goto menu
echo.
echo confirming factory state...
ssh %SSHOPTS% -p %PORT% %CMU% "grep -c libpatch /jci/sm/sm.conf 2>/dev/null; grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null; grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$'"
echo * if you see: 0, 0, FALSE  --  CMU is back to factory state
goto menu

:: ===============================================================
:: 4) Install ilshyma HUD Patch  (v16 mod, recommended)
:: ===============================================================
:install_mod
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Install ilshyma HUD Patch  * recommended ^(v16 - speed limit fixed^) ===

call :kidmixer_base
if errorlevel 1 (echo aborted -- base install failed & goto menu)

echo overlaying patched .so ^(v16^)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
set "PV_SRC=%FILES%\libpatch-blmjcicarplay-splim.so"
set "PV_DST=/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so"
set "PV_WANT=%MD5_SO_MOD%"
call :push_verify
if errorlevel 1 (echo aborted -- v16 mod .so did not land correctly & goto menu)

echo deploying speed-mirror daemon ^(v16^) + auto-launcher
:: NOTE: daemon is deployed AS splim_udpd (no .sh) — the shim looks it up via
:: `pgrep splim_udpd`, which matches argv[0]'s basename. Shipping it as
:: splim_bridge.sh would silently break the auto-launch chain.
set "PV_SRC=%FILES%\splim_bridge.sh"
set "PV_DST=/data_persist/cp-hud-mod/splim_udpd"
set "PV_WANT=%MD5_SPLIM_BRIDGE%"
call :push_verify
if errorlevel 1 (echo aborted -- daemon did not land correctly & goto menu)

set "PV_SRC=%FILES%\splim_udpd_start.sh"
set "PV_DST=/data_persist/splim_udpd_start.sh"
set "PV_WANT=%MD5_SPLIM_LAUNCHER%"
call :push_verify
if errorlevel 1 (echo aborted -- launcher did not land correctly & goto menu)

:: Chmod + wipe stale splim from prior boot (RTC=1970 confuses future-ts guard)
:: + drop legacy per-version debug logs (v5..v15) + write variant marker.
ssh %SSHOPTS% -p %PORT% %CMU% "chmod +x /data_persist/cp-hud-mod/splim_udpd /data_persist/splim_udpd_start.sh; rm -f /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/cp-hud-mod/splim_bridge_v*.sh; rm -f /mnt/data_persist/splim /data_persist/splim; rm -f /mnt/data_persist/log/splim_v5.log /mnt/data_persist/log/splim_v6.log /mnt/data_persist/log/splim_v7.log /mnt/data_persist/log/splim_v8.log /mnt/data_persist/log/splim_v9.log /mnt/data_persist/log/splim_v10.log /mnt/data_persist/log/splim_v11.log /mnt/data_persist/log/splim_v12.log /mnt/data_persist/log/splim_v13.log /mnt/data_persist/log/splim_v14.log /mnt/data_persist/log/splim_v15.log; echo v16 > /data_persist/cp-hud-mod/.variant"

echo * install complete -- every file verified. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 goto menu
echo.
echo running automatic post-install validation...
goto validate

:: ===============================================================
:: P) Install PURE KidMixer Patch  (upstream, known speed-limit issue)
:: ===============================================================
:install_pure
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Install PURE KidMixer Patch ^(known speed-limit issue^) ===

call :kidmixer_base
if errorlevel 1 (echo aborted -- base install failed & goto menu)

echo overlaying pure .so ^(in case a mod .so was on disk^)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
set "PV_SRC=%FILES%\libpatch-blmjcicarplay.so"
set "PV_DST=/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so"
set "PV_WANT=%MD5_SO_PURE%"
call :push_verify
if errorlevel 1 (echo aborted -- pure .so did not land correctly & goto menu)

echo clearing any prior speed-mod daemon + state
call :wipe_speed_mod
ssh %SSHOPTS% -p %PORT% %CMU% "echo pure > /data_persist/cp-hud-mod/.variant" >nul 2>&1

echo * pure KidMixer installed. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 goto menu
echo.
echo running automatic post-install validation...
goto validate

:: ===============================================================
:: X) Install ilshyma HUD Patch -- LEGACY mod .so (pre-v16)
:: ===============================================================
:install_mod_legacy
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Install ilshyma HUD Patch -- LEGACY pre-v16 mod .so ===

call :kidmixer_base
if errorlevel 1 (echo aborted -- base install failed & goto menu)

echo overlaying LEGACY .so ^(pre-v16, md5 %MD5_SO_MOD_LEGACY%^)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
set "PV_SRC=%FILES%\libpatch-blmjcicarplay-splim-legacy.so"
set "PV_DST=/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so"
set "PV_WANT=%MD5_SO_MOD_LEGACY%"
call :push_verify
if errorlevel 1 (echo aborted -- legacy .so did not land correctly & goto menu)

echo deploying speed-mirror daemon ^(v16^) + auto-launcher
set "PV_SRC=%FILES%\splim_bridge.sh"
set "PV_DST=/data_persist/cp-hud-mod/splim_udpd"
set "PV_WANT=%MD5_SPLIM_BRIDGE%"
call :push_verify
if errorlevel 1 (echo aborted -- daemon did not land correctly & goto menu)

set "PV_SRC=%FILES%\splim_udpd_start.sh"
set "PV_DST=/data_persist/splim_udpd_start.sh"
set "PV_WANT=%MD5_SPLIM_LAUNCHER%"
call :push_verify
if errorlevel 1 (echo aborted -- launcher did not land correctly & goto menu)

ssh %SSHOPTS% -p %PORT% %CMU% "chmod +x /data_persist/cp-hud-mod/splim_udpd /data_persist/splim_udpd_start.sh; rm -f /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/cp-hud-mod/splim_bridge_v*.sh; rm -f /mnt/data_persist/splim /data_persist/splim; echo legacy > /data_persist/cp-hud-mod/.variant"

echo * legacy mod installed. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 goto menu
echo.
echo running automatic post-install validation...
goto validate

:: ===============================================================
:: 5) Validate  --  full pass/fail with auto-fix of the daemon
:: ===============================================================
:validate
:: This is entered directly from menu (5) OR fall-through from install_mod/_pure/_legacy.
:: When entered from an install, :check_conn already ran; when entered from
:: the menu we need it too. Cheap to double-check.
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Validate installation ===
mkdir "%DIR%logs" 2>nul
for /f %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%a"
set "LOGFILE=%DIR%logs\validate_!TS!.log"

echo   collecting diagnostics from CMU ^(waiting 5s for services to settle^)...
timeout /t 5 /nobreak >nul

:: One SSH call, echoes KEY=VALUE lines we can grep out one by one.
set "VOUT=%TEMP%\mzd_validate.txt"
del /q "%VOUT%" 2>nul
ssh %SSHOPTS% -p %PORT% %CMU% "echo PRELOAD_SM=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null || echo 0); echo PRELOAD_WCP=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null || echo 0); echo NAVISUPPORTED=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$'); P=$(ps | awk '/[L]_jciCARPLAY/{print $1; exit}'); echo CARPLAY_PID=${P:-0}; if [ -n \"$P\" ]; then echo CARPLAY_LOADED=$(tr '\0' '\n' < /proc/$P/maps 2>/dev/null | grep -c libpatch-blmjcicarplay); else echo CARPLAY_LOADED=0; fi; echo SO_MD5=$(md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so 2>/dev/null | awk '{print $1}'); echo VARIANT=$(cat /data_persist/cp-hud-mod/.variant 2>/dev/null); echo DAEMON_COUNT=$(ps | grep -v grep | grep -cE 'splim_udpd|splim_bridge'); echo LAUNCHER_OK=$([ -x /data_persist/splim_udpd_start.sh ] && echo 1 || echo 0); echo DAEMON_BIN_OK=$([ -x /data_persist/cp-hud-mod/splim_udpd ] && echo 1 || echo 0)" > "%VOUT%" 2>&1
copy "%VOUT%" "!LOGFILE!" >nul 2>&1

set "PROBLEMS=0"

:: Extract each field with findstr; strip the KEY= prefix.
for /f "usebackq tokens=1,* delims==" %%a in ("%VOUT%") do (
  if /I "%%a"=="PRELOAD_SM"    set "V_PRELOAD_SM=%%b"
  if /I "%%a"=="PRELOAD_WCP"   set "V_PRELOAD_WCP=%%b"
  if /I "%%a"=="NAVISUPPORTED" set "V_NAVI=%%b"
  if /I "%%a"=="CARPLAY_PID"   set "V_PID=%%b"
  if /I "%%a"=="CARPLAY_LOADED" set "V_LOADED=%%b"
  if /I "%%a"=="SO_MD5"        set "V_SO=%%b"
  if /I "%%a"=="VARIANT"       set "V_VARIANT=%%b"
  if /I "%%a"=="DAEMON_COUNT"  set "V_DAEMON=%%b"
  if /I "%%a"=="LAUNCHER_OK"   set "V_LNC=%%b"
  if /I "%%a"=="DAEMON_BIN_OK" set "V_BIN=%%b"
)
del /q "%VOUT%" 2>nul

if not defined V_PRELOAD_SM   set "V_PRELOAD_SM=0"
if not defined V_PRELOAD_WCP  set "V_PRELOAD_WCP=0"
if not defined V_DAEMON       set "V_DAEMON=0"
if not defined V_LOADED       set "V_LOADED=0"

echo.
:: 1. LD_PRELOAD
if !V_PRELOAD_SM! GTR 0 (echo * LD_PRELOAD wired  ^(sm.conf=!V_PRELOAD_SM!  sm_WCP.conf=!V_PRELOAD_WCP!^)) else (
  if !V_PRELOAD_WCP! GTR 0 (echo * LD_PRELOAD wired  ^(sm.conf=!V_PRELOAD_SM!  sm_WCP.conf=!V_PRELOAD_WCP!^)) else (echo x LD_PRELOAD missing from both configs -- install did not take & set /a PROBLEMS+=1)
)

:: 2. NaviSupported
if /I "!V_NAVI!"=="TRUE" (echo * NaviSupported=TRUE) else (echo x NaviSupported=!V_NAVI! ^(expected TRUE^) & set /a PROBLEMS+=1)

:: 3. jciCARPLAY + shim loaded
if not "!V_PID!"=="0" (
  if !V_LOADED! GTR 0 (echo * jciCARPLAY running ^(pid=!V_PID!^) with our shim loaded) else (echo x jciCARPLAY running ^(pid=!V_PID!^) but shim NOT loaded -- try another reboot & set /a PROBLEMS+=1)
) else (
  echo x jciCARPLAY is not running
  set /a PROBLEMS+=1
)

:: 4. .so identity on disk
if /I "!V_SO!"=="%MD5_SO_MOD%"        (echo * mod .so on disk: v16 ^(speed-limit patch^))     else (
  if /I "!V_SO!"=="%MD5_SO_MOD_LEGACY%" (echo * mod .so on disk: legacy pre-v16 ^(speed-limit patch^)) else (
    if /I "!V_SO!"=="%MD5_SO_PURE%"     (echo ! PURE KidMixer .so on disk -- no speed-limit patch ^(normal for menu P^)) else (
      if "!V_SO!"=="" (echo x no .so found on disk & set /a PROBLEMS+=1) else (echo ! unrecognized .so md5: !V_SO!)
    )
  )
)

:: 5. speed daemon (skip if variant=pure)
if /I "!V_VARIANT!"=="pure" (
  echo   PURE variant -- no speed daemon expected ^(this is normal^)
) else (
  if !V_DAEMON! GTR 0 (
    echo * speed-mirror daemon is running ^(!V_DAEMON! process^(es^)^)
  ) else (
    echo ! speed-mirror daemon is NOT running -- attempting to auto-start
    if "!V_BIN!"=="1" (
      if "!V_LNC!"=="1" (
        call :force_start_quiet
        timeout /t 3 /nobreak >nul
        set "V_RECHECK=0"
        :: NO `^|` here — inside double quotes CMD leaves `^` literal, and it
        :: would then reach the remote shell verbatim, breaking every pipe.
        :: The pipes below are protected from CMD's pipe-parsing simply by
        :: being inside the double-quoted argument to ssh.exe.
        for /f "usebackq" %%a in (`ssh %SSHOPTS% -p %PORT% %CMU% "ps | grep -v grep | grep -cE 'splim_udpd|splim_bridge'"`) do set "V_RECHECK=%%a"
        if !V_RECHECK! GTR 0 (
          echo   * auto-fix worked -- daemon is now running
        ) else (
          echo   x auto-fix FAILED -- daemon still not running
          echo   full log: !LOGFILE!
          echo   try option D ^(diagnose^) or option F ^(force-start^)
          set /a PROBLEMS+=1
        )
      ) else (echo x launcher missing -- re-run option 4 & set /a PROBLEMS+=1)
    ) else (echo x daemon binary missing -- re-run option 4 & set /a PROBLEMS+=1)
  )
)

echo.
if !PROBLEMS!==0 (
  echo * ============ VALIDATION PASSED ============
  echo   HUD arrows ready; speed limit will populate while driving
  echo   log: !LOGFILE!
) else (
  echo x ============ VALIDATION FOUND !PROBLEMS! PROBLEM^(S^) ============
  echo   full diagnostic saved: !LOGFILE!
  echo   option D = verbose dump    option F = retry starting daemon
)
goto menu

:: ===============================================================
:: Helper: force_start_quiet — used internally by validate()
:: ===============================================================
:force_start_quiet
ssh %SSHOPTS% -p %PORT% %CMU% "pkill -9 splim_bridge 2>/dev/null; kill -9 $(pgrep splim_udpd) 2>/dev/null; rm -f /mnt/data_persist/splim /data_persist/splim; sleep 1; nohup /data_persist/splim_udpd_start.sh >/tmp/splim_launcher.log 2>&1 &" >nul 2>&1
exit /b 0

:: ===============================================================
:: F) Force-start speed daemon — verbose
:: ===============================================================
:force_start_daemon
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Force-restart speed-mirror daemon ===
ssh %SSHOPTS% -p %PORT% %CMU% "echo '--- killing anything old ---'; pkill -9 splim_bridge 2>/dev/null; pkill -9 splim_udpd 2>/dev/null; kill -9 $(pgrep splim_udpd) 2>/dev/null; sleep 1; echo '--- clearing stale splim file ---'; rm -f /mnt/data_persist/splim /data_persist/splim /tmp/splim_v*_last /tmp/splim_v*_cache; rm -rf /tmp/splim_v*_cache; echo '--- starting via launcher ---'; if [ ! -x /data_persist/splim_udpd_start.sh ]; then echo '  ! launcher missing -- install first (menu 4)'; exit 1; fi; if [ ! -x /data_persist/cp-hud-mod/splim_udpd ]; then echo '  ! daemon binary missing -- install first (menu 4 or X)'; exit 1; fi; nohup /data_persist/splim_udpd_start.sh >/tmp/splim_launcher.log 2>&1 &  sleep 3; echo '--- after 3s ---'; DP=$(ps | grep -v grep | grep -E 'splim_bridge|splim_udpd|dbus-monitor'); if [ -n \"$DP\" ]; then echo \"$DP\" | sed 's/^/  /'; else echo '  ! still no processes running'; fi; echo '  launcher stderr:'; tail -20 /tmp/splim_launcher.log 2>/dev/null | sed 's/^/    /'"
echo.
echo now start CarPlay navigation in the car and use option T ^(live tail^).
echo you should see 'got splim=NN unit=2' lines each time a speed sign is captured.
goto menu

:: ===============================================================
:: D) Diagnose  --  verbose dump of everything
:: ===============================================================
:diagnose
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Diagnose speed-limit chain ^(verbose^) ===
ssh %SSHOPTS% -p %PORT% %CMU% "echo; echo '--- 1. LD_PRELOAD wiring ---'; grep -c libpatch /jci/sm/sm.conf 2>/dev/null | awk '{print \"  sm.conf preload lines: \"$0}'; grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null | awk '{print \"  sm_WCP.conf preload lines: \"$0}'; grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | tr -d '<>' | awk '{print \"  \"$0}'; echo; echo '--- 2. jciCARPLAY process ---'; P=$(ps | awk '/[L]_jciCARPLAY/{print $1; exit}'); if [ -n \"$P\" ]; then echo \"  pid=$P\"; tr '\0' '\n' < /proc/$P/maps 2>/dev/null | grep -o libpatch-blmjcicarplay | head -1 | awk '{print \"  loaded: \"$0}'; tr '\0' '\n' < /proc/$P/environ 2>/dev/null | grep LD_PRELOAD | awk '{print \"  \"$0}'; else echo '  ! jciCARPLAY not running'; fi; echo; echo '--- 3. .so on disk + variant ---'; md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so 2>/dev/null | awk '{print \"  \"$0}'; echo \"  variant marker: $(cat /data_persist/cp-hud-mod/.variant 2>/dev/null || echo '(none)')\"; echo; echo '--- 4. speed daemon ---'; DP=$(ps | grep -v grep | grep -E 'splim_bridge|splim_udpd|dbus-monitor'); if [ -n \"$DP\" ]; then echo \"$DP\" | awk '{print \"  \"$0}'; else echo '  ! no splim processes running'; fi; echo; echo '--- 5. splim file ---'; for P in /mnt/data_persist/splim /data_persist/splim; do if [ -e \"$P\" ]; then printf '  %s -> ' \"$P\"; ls -la \"$P\" | awk '{print $5\" bytes, mtime \"$6\" \"$7\" \"$8}'; printf '    content: '; cat \"$P\" 2>/dev/null; echo; else echo \"  $P -> does not exist\"; fi; done; echo; echo '--- 6. auto-launcher ---'; ls -la /data_persist/splim_udpd_start.sh 2>/dev/null | awk '{print \"  \"$0}'; [ -f /data_persist/splim_udpd_start.sh ] || echo '  ! launcher missing'; echo; echo '--- 7. daemon log ---'; L=$(ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1); if [ -n \"$L\" ]; then echo \"  $L:\"; tail -15 \"$L\" | sed 's/^/    /'; else echo '  ! no splim_v*.log found'; fi; echo; echo '--- 8. RTC ---'; date | awk '{print \"  \"$0}'"
goto menu

:: ===============================================================
:: T) Live-tail speed-daemon log
:: ===============================================================
:tail_log
call :check_conn
if errorlevel 1 goto menu
echo. & echo === Live tail speed-daemon log ^(Ctrl+C to exit^) ===
ssh %SSHOPTS% -p %PORT% %CMU% "ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1 | xargs -r tail -F 2>/dev/null"
goto menu

:: ===============================================================
:: C) CarPlay HUD arrow debug log
:: ===============================================================
:carplay_log
call :check_conn
if errorlevel 1 goto menu
echo. & echo === CarPlay HUD arrow debug log ^(/tmp/carplay_bridge.log^) ===
ssh %SSHOPTS% -p %PORT% %CMU% "if [ ! -s /tmp/carplay_bridge.log ]; then echo '  (empty or missing -- either no CarPlay nav session has run yet this boot, or this .so build does not emit debug output)'; exit 0; fi; echo \"  size: $(wc -c < /tmp/carplay_bridge.log) bytes\"; echo; echo '  distinct maneuver/street lines seen:'; grep -iE 'maneuver|street|distance|nextManeuver' /tmp/carplay_bridge.log 2>/dev/null | sort -u | sed 's/^/    /' | head -30; echo; echo '  any send/clear failures (rc!=0):'; grep -iE 'failed rc=|exception swallowed|conn_create failed|conn_connect failed' /tmp/carplay_bridge.log 2>/dev/null | sed 's/^/    /' | head -20; echo; echo '  last 30 lines:'; tail -30 /tmp/carplay_bridge.log | sed 's/^/    /'"
goto menu
