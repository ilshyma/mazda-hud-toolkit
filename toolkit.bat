@echo off
:: ============================================================================
::  IF THIS SCRIPT SPITS OUT LOTS OF "'t' is not recognized as an internal or
::  external command" / "cannot find batch label" / "Missing expression after
::  ',' in pipeline element" ERRORS -- your Windows cmd.exe is choking on this
::  .bat for reasons that have nothing to do with the toolkit itself.
::
::  QUICKEST FIX: run this toolkit through Git Bash instead of cmd.exe.
::    1. Install Git for Windows (one click): https://git-scm.com/download/win
::    2. Open "Git Bash" from the Start menu.
::    3. cd into this folder.  Example:
::         cd /c/Users/<your_user>/Downloads/mazda-hud-toolkit/mazda-hud-toolkit
::    4. Run:   bash toolkit.sh
::
::  Everything except "Create USB stick" works end-to-end through Git Bash
::  (backup, install, rollback, validate, SSH bootstrap). For the USB-create
::  step you still need cmd.exe (option 1 in toolkit.bat) or format + copy the
::  files/usb_unlock/ tree by hand.
:: ============================================================================
::  Mazda CMU CarPlay-HUD toolkit -- Windows 10/11  (sync-parity with toolkit.sh)
:: ============================================================================
::  Requires: OpenSSH Client (Win10 1803+ ships it; verify under Settings >
::  Optional Features), PowerShell 5+ (bundled with every Win10/11).
::
::  MAIN MENU -- everything a normal user needs:
::    1  Create USB stick  (SSH unlock + HUD patch on one FAT32/MZD stick)
::    2  Backup CMU
::    3  Rollback          (removes EVERY HUD patch, back to stock)
::    4  Install HUD patch (CarPlay + Android Auto, md5-verified + auto-validate)
::
::  ADVANCED (A): V S D | L P X K F T C   (same letters as toolkit.sh)
::
::  Windows hardening in this build:
::   * UTF-8 code page (chcp 65001) with save/restore so Cyrillic in paths /
::     volume labels / Explorer output does not turn into mojibake.
::   * Elevation detection (`net session`) + optional auto-format of the USB
::     via PowerShell Format-Volume when admin; otherwise fallback to manual
::     Explorer format (same end state).
::   * Removable-drive enumeration via Get-CimInstance Win32_LogicalDisk +
::     Get-Disk BusType=USB fallback (catches drives Explorer shows but
::     Win32_LogicalDisk missed on some systems).
::   * MD5-sweep of EVERY critical file on the stick (not just hud-mod), with
::     the exact same file list as toolkit.sh:make_usb().
::   * `!TARGET!`  (no trailing backslash) when calling PowerShell -- avoids
::     Win-arg-parser swallowing `\"` into `"`.
::   * Progress dot in :wait_for_ssh actually visible (no stray `>nul`).
::   * Advanced menu LOOPS back to Advanced (not Main), matching the .sh.
::   * Visual markers *  x  !  >  mirror the .sh colored symbols.
::   * `pkill -f` is NEVER used (`-f` matches the ssh wrapper cmdline itself
::     and self-kills the whole chain mid-run -- see toolkit.sh:wipe_speed_mod).
::   * Daemon deployed as `splim_udpd` (NO .sh suffix) -- pgrep in the shim
::     matches on argv[0]'s basename.
::   * `.variant` marker written for every variant (pure/v16/legacy).
::   * Stale `splim` + per-version debug logs wiped before every (re)install.
::   * WMIC references removed; timestamps come from PowerShell Get-Date
::     (WMIC is deprecated and gone by default on Win11 22000+).
::   * All ssh / scp invocations use the quoted-key %SSHOPTS% that survives
::     spaces in the toolkit folder path.
:: ============================================================================
setlocal EnableDelayedExpansion EnableExtensions

:: --- UTF-8 code page (saved + restored on exit) ----------------------------
set "ORIG_CP="
for /f "tokens=2 delims=:" %%p in ('chcp 2^>nul') do set "ORIG_CP=%%p"
if defined ORIG_CP set "ORIG_CP=!ORIG_CP: =!"
chcp 65001 >nul 2>&1

:: --- paths / endpoint ------------------------------------------------------
set "DIR=%~dp0"
set "FILES=%DIR%files"
set "KEY=%DIR%id_rsa_cmu"
set "UNIFIED=%FILES%\unified"
set "CMU=cmu@192.168.53.1"
set "PORT=36000"
set "UNIFIED_REMOTE=/tmp/hud-mod"
set "UNIFIED_DIR=/data_persist/oem-aa-mod"

:: NOTE: SSHOPTS has NO surrounding double quotes on the `set` line itself --
:: those would end at the first inner quote around %KEY%, leaving SSHOPTS
:: truncated to just `-i "`. Every reference below writes `%SSHOPTS%` unquoted
:: so the inner quotes on the KEY path survive to ssh.exe.
set SSHOPTS=-i "%KEY%" -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes

:: --- toolkit version (read from files\VERSION, one source of truth) --------
:: Shown in the main-menu header; the CMU-side scripts read their own copy
:: of VERSION (which travels on the USB stick and in the SSH install folder)
:: and stamp it into every run.log + the on-screen FACTS line.
set "MOD_VERSION=unknown"
if exist "%FILES%\VERSION" (
  for /f "usebackq delims=" %%v in ("%FILES%\VERSION") do set "MOD_VERSION=%%v"
)

:: --- expected md5s of shipped payloads -------------------------------------
set "MD5_SO_PURE=0ce29da4f16f72b0b8f931bee88ff332"
set "MD5_SO_MOD=faf82efb028c6af9898122a5ff5833be"
set "MD5_SO_MOD_LEGACY=c8800f0e743612543ecae705738c987e"
set "MD5_SPLIM_BRIDGE=0aa7119da7bbbdb25a3ab271e238ae44"
set "MD5_SPLIM_LAUNCHER=26cdb9e1a2333425e57923b334c5cc50"

:: --- visual markers (same meaning as toolkit.sh ok/err/warn/info) ----------
set "M_OK=  * "
set "M_ERR=  x "
set "M_WARN=  ! "
set "M_INFO=  > "

:: --- preflight: ONLY things every path (USB creation included) needs --------
:: PowerShell is required even for :usb (enumeration + Format-Volume + md5),
:: so we hard-check it here. ssh / scp / id_rsa_cmu are needed only by CMU
:: operations, so :check_conn verifies them lazily -- creating a USB stick
:: without the SSH key still works.
where powershell  >nul 2>&1
if errorlevel 1 (echo. & echo ERROR: powershell.exe not found. ^(Highly unusual on Windows.^) & pause & goto :end_err)

:: Restrict key perms if the key exists (OpenSSH refuses world-readable keys).
:: Silent no-op when the key is missing or already restricted.
if exist "%KEY%" icacls "%KEY%" /inheritance:r /grant:r "%USERNAME%":R >nul 2>&1

:: Detect elevation once (used by :usb to offer PowerShell auto-format).
net session >nul 2>&1
if %errorlevel%==0 (set "IS_ADMIN=1") else (set "IS_ADMIN=0")

goto menu

:: ===========================================================================
:: MAIN MENU
:: ===========================================================================
:menu
echo.
echo ==========================================================
echo  Mazda CMU HUD toolkit -- CarPlay + Android Auto    v!MOD_VERSION!
echo ==========================================================
echo   1  Create USB stick  ^(SSH unlock + HUD patch on one stick^)
echo   2  Backup CMU
echo   3  Rollback  ^(remove every HUD patch, back to stock^)
echo   4  Install HUD patch  ^(CarPlay + Android Auto^)
echo ==========================================================
echo   B  Bootstrap SSH key  ^(first time only -- install the id_rsa_cmu key^)
echo   A  Advanced options
echo   0  Exit
echo.
set "C="
set /p "C=> "
if /I "!C!"=="1" (call :usb            & goto menu)
if /I "!C!"=="2" (call :backup         & goto menu)
if /I "!C!"=="3" (call :rollback_all   & goto menu)
if /I "!C!"=="4" (call :install_unified& goto menu)
if /I "!C!"=="B" (call :bootstrap_ssh  & goto menu)
if /I "!C!"=="A" (call :advanced       & goto menu)
if /I "!C!"=="0" goto :end
if /I "!C!"=="Q" goto :end
if "!C!"=="" goto menu
echo invalid.
goto menu

:advanced
echo.
echo ==========================================================
echo  ADVANCED -- not needed for normal use
echo ==========================================================
echo   V  Validate installation  ^(also runs by itself after install^)
echo   S  Check SSH connection
echo   D  Full diagnostic dump
echo.
echo   Older CarPlay-only patches
echo   L  Install ilshyma HUD Patch v16  ^(CarPlay only^)
echo   P  Install PURE KidMixer Patch    ^(CarPlay only, no speed-limit fix^)
echo   X  Install legacy pre-v16 mod .so ^(speed-limit fallback^)
echo   K  KidMixer rollback  ^(old v16 rollback path^)
echo   F  Force-start v16 speed daemon
echo   T  Live-tail v16 daemon log
echo   C  CarPlay HUD arrow debug log
echo.
echo   0  Back
echo.
set "C="
set /p "C=> "
if /I "!C!"=="V" (call :validate            & goto advanced)
if /I "!C!"=="S" (call :check_verbose       & goto advanced)
if /I "!C!"=="D" (call :diagnose            & goto advanced)
if /I "!C!"=="L" (call :install_mod         & goto advanced)
if /I "!C!"=="P" (call :install_pure        & goto advanced)
if /I "!C!"=="X" (call :install_mod_legacy  & goto advanced)
if /I "!C!"=="K" (call :rollback            & goto advanced)
if /I "!C!"=="F" (call :force_start_daemon  & goto advanced)
if /I "!C!"=="T" (call :tail_log            & goto advanced)
if /I "!C!"=="C" (call :carplay_log         & goto advanced)
if /I "!C!"=="0" exit /b 0
if "!C!"=="" goto advanced
echo invalid.
goto advanced

:: ===========================================================================
:: Clean exit (restore original code page)
:: ===========================================================================
:end
if defined ORIG_CP chcp !ORIG_CP! >nul 2>&1
endlocal
exit /b 0

:end_err
if defined ORIG_CP chcp !ORIG_CP! >nul 2>&1
endlocal
exit /b 1

:: ===========================================================================
:: :check_conn  --  silent SSH reachability check (returns 0 ok, 1 fail).
:: :check_verbose -- menu "S": same, but prints uname -a / uptime.
:: Windows ping returns 0 even for "Destination host unreachable" replies,
:: so we grep for a TTL= line (an actual response from the target).
:: ===========================================================================
:check_conn
:: Lazy preflight: ssh / scp / id_rsa_cmu are only needed on the CMU path.
where ssh >nul 2>&1
if errorlevel 1 (echo %M_ERR%ssh.exe not found. Install OpenSSH Client via Settings ^> Apps ^> Optional Features. & exit /b 1)
where scp >nul 2>&1
if errorlevel 1 (echo %M_ERR%scp.exe not found. Install OpenSSH Client via Settings ^> Apps ^> Optional Features. & exit /b 1)
if not exist "%KEY%" (echo %M_ERR%SSH key missing at %KEY% -- re-download the toolkit ZIP. & exit /b 1)
ping -n 2 -w 1000 192.168.53.1 | find "TTL=" >nul
if errorlevel 1 (
  echo %M_ERR%CMU not reachable -- insert USB and tap SSH in XSS menu on CMU.
  exit /b 1
)
ssh %SSHOPTS% -p %PORT% %CMU% "true" >nul 2>&1
if errorlevel 1 (
  echo %M_ERR%SSH failed -- retry via USB / XSS.
  exit /b 1
)
exit /b 0

:check_verbose
echo.
echo === SSH check ===
where ssh >nul 2>&1
if errorlevel 1 (echo %M_ERR%ssh.exe not found. Install OpenSSH Client. & exit /b 1)
if not exist "%KEY%" (echo %M_ERR%SSH key missing at %KEY% -- re-download the toolkit ZIP. & exit /b 1)
ping -n 3 -w 1000 192.168.53.1 | find "TTL=" >nul
if errorlevel 1 (echo %M_ERR%CMU not reachable. Insert USB and tap SSH in XSS menu. & exit /b 1)
ssh %SSHOPTS% -p %PORT% %CMU% "uname -a && uptime"
if errorlevel 1 (echo %M_ERR%SSH failed. & exit /b 1)
echo %M_OK%SSH ok
exit /b 0

:: ===========================================================================
:: :wait_for_ssh  --  poll every 5 s (up to 5 min) for SSH after a reboot.
:: Prints a `.` per attempt. 0 = back, 1 = timeout.
:: ===========================================================================
:wait_for_ssh
echo.
echo %M_WARN%CMU is rebooting -- this takes about 90 seconds.
echo %M_INFO%In the car: once the screen comes back, Media -^> USB -^> tap any mp3
echo %M_INFO%  ^(or let it autoplay^) -^> tap SSH in the XSS menu.
echo %M_INFO%Detecting SSH automatically -- checking every 5s for up to 5 min.
echo.
set /a WAIT_ELAPSED=0
:wait_for_ssh_loop
ping -n 2 -w 1000 192.168.53.1 | find "TTL=" >nul
if not errorlevel 1 (
  ssh %SSHOPTS% -p %PORT% %CMU% "true" >nul 2>&1
  if not errorlevel 1 (echo. & echo %M_OK%SSH is back ^(after !WAIT_ELAPSED!s^) & exit /b 0)
)
set /a WAIT_ELAPSED+=5
if !WAIT_ELAPSED! GEQ 300 (echo. & echo %M_WARN%SSH did not come back within 300s. Run Advanced -^> V ^(Validate^) when back. & exit /b 1)
<nul set /p "=."
timeout /t 5 /nobreak >nul
goto wait_for_ssh_loop

:: ===========================================================================
:: Helper: md5_local  FILE  ->  LMD5 (lowercase hex)
:: Uses Get-FileHash (PowerShell 4+ / Win 8.1+). certutil output format
:: differs between Windows versions, so we do not use it.
:: ===========================================================================
:md5_local
set "LMD5="
for /f "usebackq delims=" %%h in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-FileHash -Algorithm MD5 -LiteralPath '%~1').Hash.ToLower()"`) do set "LMD5=%%h"
exit /b 0

:: ===========================================================================
:: Helper: push_verify  --  scp SRC to CMU:DST, verify remote md5 == WANT.
:: Retries up to 3 times. Args passed via env (CMD lacks positional args).
:: ===========================================================================
:push_verify
set /a PV_TRY=0
:push_verify_loop
set /a PV_TRY+=1
if "!PV_TRY!"=="1" echo %M_INFO%-^> !PV_SRC! -^> !PV_DST!
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
echo %M_ERR%giving up on !PV_SRC! after 3 attempts
exit /b 1

:: ===========================================================================
:: Helper: kidmixer_base  --  push KidMixer install.sh + pure .so and run it.
:: Idempotent on CMU side; retries up to 3 times.
:: ===========================================================================
:kidmixer_base
if not exist "%FILES%\install.sh"                (echo %M_ERR%local file missing: install.sh                & exit /b 1)
if not exist "%FILES%\libpatch-blmjcicarplay.so" (echo %M_ERR%local file missing: libpatch-blmjcicarplay.so & exit /b 1)
echo %M_INFO%copying KidMixer install.sh + pure .so
set /a KB_TRY=0
:kidmixer_base_loop
set /a KB_TRY+=1
if !KB_TRY! GTR 1 echo     retry !KB_TRY!/3...
ssh %SSHOPTS% -p %PORT% %CMU% "mkdir -p /tmp/cp-hud-install" && ^
scp %SSHOPTS% -P %PORT% "%FILES%\install.sh"                %CMU%:/tmp/cp-hud-install/ && ^
scp %SSHOPTS% -P %PORT% "%FILES%\libpatch-blmjcicarplay.so" %CMU%:/tmp/cp-hud-install/
if exist "%FILES%\VERSION" scp %SSHOPTS% -P %PORT% "%FILES%\VERSION" %CMU%:/tmp/cp-hud-install/ >nul 2>&1
ssh %SSHOPTS% -p %PORT% %CMU% "cd /tmp/cp-hud-install && sh install.sh"
if not errorlevel 1 exit /b 0
if !KB_TRY! LSS 3 (timeout /t 2 /nobreak >nul & goto kidmixer_base_loop)
echo %M_ERR%KidMixer base install failed after 3 attempts
exit /b 1

:: ===========================================================================
:: Helper: wipe_speed_mod  --  kill our speed daemon + wipe its state on CMU.
:: NEVER uses `pkill -f`: this ssh command's cmdline CONTAINS the words
:: "splim_bridge"/"splim_udpd", so `pkill -f splim_bridge` would SIGKILL the
:: script that is running it, mid-line, with zero output. Plain pkill/pgrep
:: match only the process's short "comm" name (splim_udpd for the daemon,
:: "sh" for this management script) -- correct target, no self-match. This
:: is the exact fix as toolkit.sh:wipe_speed_mod().
:: ===========================================================================
:wipe_speed_mod
ssh %SSHOPTS% -p %PORT% %CMU% "pkill -9 splim_bridge 2>/dev/null; pkill -9 splim_udpd 2>/dev/null; kill -9 $(pgrep splim_udpd) 2>/dev/null; rm -f /data_persist/splim_udpd_start.sh /data_persist/cp-hud-mod/splim_bridge*.sh /data_persist/cp-hud-mod/splim_udpd /data_persist/cp-hud-mod/.variant /data_persist/splim /mnt/data_persist/splim /tmp/splim_v*_cache /tmp/splim_v*_last; rm -rf /tmp/splim_v*_cache; sleep 1; true" >nul 2>&1
exit /b 0

:: ===========================================================================
:: B) Bootstrap SSH key -- first-time setup, no key / no password required.
::
:: The toolkit talks to the CMU as cmu@192.168.53.1 using the id_rsa_cmu
:: private key. That key is NOT shipped with the public release -- it must be
:: generated locally AND its public half installed in the CMU's authorized_keys.
:: The USB stick (menu 1) only enables sshd + sets the password `cmu:jci`.
:: This bootstrap bridges the gap: generates id_rsa_cmu if missing, pipes the
:: pub key into the CMU using the one-time password `jci`, then verifies key
:: auth works. Required once per computer; the key stays on disk and the CMU
:: side survives reboots (authorized_keys lives in /data_persist).
:: ===========================================================================
:bootstrap_ssh
echo.
echo === Bootstrap SSH key -- first-time setup ===
echo %M_INFO%This installs the id_rsa_cmu SSH key on the CMU so every other menu
echo %M_INFO%action works without typing a password. One-time, per computer.
echo.

:: 1) ssh-keygen presence
where ssh-keygen >nul 2>&1
if errorlevel 1 (echo %M_ERR%ssh-keygen.exe not found. Install OpenSSH Client via Settings ^> Apps ^> Optional Features. & exit /b 1)
where ssh        >nul 2>&1
if errorlevel 1 (echo %M_ERR%ssh.exe not found. Install OpenSSH Client. & exit /b 1)

:: 2) Generate key if missing (2048-bit RSA; the CMU's old OpenSSH does not grok ed25519).
if not exist "%KEY%" (
  echo %M_INFO%generating a fresh id_rsa_cmu ^(2048-bit RSA, no passphrase^)...
  ssh-keygen -t rsa -b 2048 -N "" -f "%KEY%" -C "mazda-hud-toolkit" >nul
  if errorlevel 1 (echo %M_ERR%ssh-keygen failed & exit /b 1)
  icacls "%KEY%" /inheritance:r /grant:r "%USERNAME%":R >nul 2>&1
  echo %M_OK%key created: %KEY%
) else (
  echo %M_OK%key already present: %KEY% ^(reusing it^)
)
if not exist "%KEY%.pub" (echo %M_ERR%public half missing: %KEY%.pub -- delete %KEY% and run B again & exit /b 1)

:: 3) CMU reachable?
echo %M_INFO%checking the CMU is reachable at 192.168.53.1...
ping -n 2 -w 1000 192.168.53.1 | find "TTL=" >nul
if errorlevel 1 (
  echo %M_ERR%CMU not reachable. Enable SSH first:
  echo %M_ERR%  1. Run menu option 1 to prepare a USB stick
  echo %M_ERR%  2. In the car, insert it -^> Media -^> USB -^> tap any mp3 -^> SSH in XSS menu
  echo %M_ERR%  3. Connect your computer to the CMU Wi-Fi, then re-run B
  exit /b 1
)
echo %M_OK%CMU is reachable

:: 4) Push the pub key via password auth. Windows OpenSSH does not ship
:: ssh-copy-id, so we pipe the key into the remote via `type pub | ssh ...`.
:: The password `jci` was set by the USB XSS unlock (`cmu:jci` chpasswd line).
echo.
echo %M_WARN%You will be asked for the CMU password now. Type: jci
echo %M_WARN%^(this is set by the USB XSS unlock; it is NOT your Windows password^)
echo.
type "%KEY%.pub" | ssh -o PubkeyAuthentication=no -o PasswordAuthentication=yes -o StrictHostKeyChecking=no -p %PORT% %CMU% "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
if errorlevel 1 (
  echo %M_ERR%could not install the public key
  echo %M_ERR%  common causes: wrong password ^(correct is 'jci'^), SSH disabled again
  echo %M_ERR%  ^(sshd dies on reboot -- repeat USB -^> XSS -^> SSH, then re-run B^)
  exit /b 1
)
echo %M_OK%public key installed on CMU

:: 5) Verify key auth works end-to-end
echo %M_INFO%verifying key-based login...
ssh %SSHOPTS% -o PasswordAuthentication=no -p %PORT% %CMU% "uname -a && uptime"
if errorlevel 1 (echo %M_ERR%key auth still refused. Try B again, or run Advanced -^> S to debug. & exit /b 1)
echo.
echo %M_OK%============ BOOTSTRAP DONE ============
echo %M_INFO%Every menu option is unlocked now.
echo %M_INFO%Next: option 2 ^(backup^), then option 4 ^(install HUD patch^).
exit /b 0

:: ===========================================================================
:: 1) Create USB stick  --  removable drive picker, format (auto if admin,
::    otherwise manual), copy payload, md5-verify every critical file.
:: ===========================================================================
:usb
echo.
echo === Create USB stick ===
echo %M_INFO%detecting removable USB drives...
echo.

:: Enumerate removable drives (DriveType=2 in Win32_LogicalDisk).
set "PSOUT=%TEMP%\mzd_disks.txt"
del /q "%PSOUT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='SilentlyContinue'; $rows = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' | ForEach-Object { $lbl = if ($_.VolumeName) { $_.VolumeName } else { '(no label)' }; '{0}|{1}|{2:N1} GB' -f $_.DeviceID, $lbl, ($_.Size/1GB) }; if (-not $rows) { $rows = Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter } | ForEach-Object { $lbl = if ($_.FileSystemLabel) { $_.FileSystemLabel } else { '(no label)' }; '{0}:|{1}|{2:N1} GB' -f $_.DriveLetter, $lbl, ($_.Size/1GB) } }; $rows | Out-File -Encoding ASCII '%PSOUT%'" 2>nul
if not exist "%PSOUT%" (
  echo %M_ERR%PowerShell failed to enumerate drives.
  echo       Try: powershell -Command "Get-CimInstance Win32_LogicalDisk"
  echo       If that also fails, PowerShell is disabled by group policy.
  exit /b 1
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
if !N!==0 (
  echo %M_ERR%no removable drive found. Plug one in and pick option 1 again.
  exit /b 1
)
echo   0  cancel
echo.
set "CH="
set /p "CH=> "
if "!CH!"=="" (echo cancelled & exit /b 0)
if "!CH!"=="0" (echo cancelled & exit /b 0)
set "TARGET=!DRIVE_%CH%!"
if "!TARGET!"=="" (echo %M_ERR%invalid choice & exit /b 1)

:: Must have the drive letter without the trailing backslash for most ops;
:: build the backslash-terminated form for xcopy/Join-Path separately.
set "TARGET_BS=!TARGET!\"

echo.
echo %M_WARN%about to WIPE !TARGET!  ^(!LABEL_%CH%!, !SIZE_%CH%!^)
set "OK="
set /p "OK=confirm? [y/N] > "
if /I not "!OK!"=="y" (echo cancelled & exit /b 0)

:: --- Format phase ----------------------------------------------------------
:: Labels inside ()-blocks are unsafe in cmd (they implicitly close the block
:: and corrupt the parser state). Flag-driven flow instead: decide what to do,
:: run the chosen branch in its own non-nested if.
echo.
echo %M_INFO%step 1/4 . formatting !TARGET! as FAT32 with label MZD
set "FMT_MODE=manual"
if "!IS_ADMIN!"=="1" (
  echo %M_INFO%  admin detected -- using PowerShell Format-Volume
  set "FMT_LETTER=!TARGET:~0,1!"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; try { Format-Volume -DriveLetter '!FMT_LETTER!' -FileSystem FAT32 -NewFileSystemLabel 'MZD' -Confirm:$false -Force | Out-Null; 'OK' } catch { 'FAIL: ' + $_.Exception.Message }" > "%TEMP%\mzd_fmt.txt" 2>&1
  type "%TEMP%\mzd_fmt.txt"
  findstr /B /L "OK" "%TEMP%\mzd_fmt.txt" >nul
  if not errorlevel 1 set "FMT_MODE=done"
  del /q "%TEMP%\mzd_fmt.txt" 2>nul
)
if /I "!FMT_MODE!"=="done" (
  echo %M_OK%  formatted
) else (
  if "!IS_ADMIN!"=="1" echo %M_WARN%  auto-format failed. Falling back to manual format.
  if "!IS_ADMIN!"=="0" echo %M_WARN%  not elevated -- cannot auto-format. Please do this now:
  echo %M_INFO%    Explorer -^> right-click !TARGET! -^> Format...
  echo %M_INFO%      File system: FAT32   Volume label: MZD   Quick Format: ON
  echo.
  set "OK="
  set /p "OK=formatted as FAT32 with label MZD? [y/N] > "
  if /I not "!OK!"=="y" (echo cancelled & exit /b 0)
)

:: Wait for the drive to be ready after format (give the OS a few seconds).
set /a USB_WAIT=0
:usb_wait_mount
if exist "!TARGET_BS!" goto usb_mounted
set /a USB_WAIT+=1
if !USB_WAIT! GEQ 20 (echo %M_ERR%!TARGET! not accessible after 20s & exit /b 1)
timeout /t 1 /nobreak >nul
goto usb_wait_mount
:usb_mounted

:: --- Copy payload ----------------------------------------------------------
echo %M_INFO%step 2/4 . copying payload
xcopy /E /I /Y "%FILES%\usb_unlock\*" "!TARGET_BS!" >nul
if errorlevel 1 (echo %M_ERR%copy failed & exit /b 1)

:: Mp3s at the drive ROOT too -- some CMUs autoplay the first root-level
:: audio track on insert, which pops the XSS menu with zero manual action.
xcopy /Y "%FILES%\usb_unlock\mp3\*.mp3" "!TARGET_BS!" >nul 2>nul

:: hud-mod/ rides on the same stick: XSS menu buttons HUD+ / HUD- / HUD?
:: run hud-mod\usb_run.sh. Every file is md5-compared with the toolkit copy.
if exist "%UNIFIED%\usb_run.sh" (
  echo %M_INFO%  copying CarPlay + Android Auto HUD patch to !TARGET!\hud-mod\
  xcopy /E /I /Y "%UNIFIED%\*" "!TARGET_BS!hud-mod\" >nul
  if errorlevel 1 (echo %M_ERR%copy of hud-mod failed & exit /b 1)
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$bad=0; Get-ChildItem -LiteralPath '%UNIFIED%' -File | ForEach-Object { $d = Join-Path '!TARGET_BS!hud-mod' $_.Name; if (-not (Test-Path -LiteralPath $d) -or (Get-FileHash -Algorithm MD5 -LiteralPath $_.FullName).Hash -ne (Get-FileHash -Algorithm MD5 -LiteralPath $d).Hash) { Write-Output ('  CORRUPT/MISSING: hud-mod\' + $_.Name); $bad++ } }; exit $bad"
  if errorlevel 1 (echo %M_ERR%hud-mod on the stick does not match the toolkit -- re-run option 1 & exit /b 1)
  echo %M_OK%  hud-mod verified
)

:: The 'h' dispatcher sits at the stick root; HUD buttons fire
:: "sh /mnt/sda1/h <action> <token>" via the CGI (URL-length limit).
if exist "%FILES%\usb_unlock\h" (
  copy /Y "%FILES%\usb_unlock\h" "!TARGET_BS!h" >nul
  if errorlevel 1 (echo %M_ERR%copy of h dispatcher failed & exit /b 1)
)

:: --- CVE-2024-8359 .up filename injection payloads -------------------------
:: The CMU reflash scanner (libjcireflashua.so) passes .up filenames to
:: system() unsanitised. Filenames encode "sh /mnt/sd[abcd]1/t" (or /tmp/mnt...)
:: via awk sprintf. Two files cover both mount-point prefixes; the 't'
:: trampoline deduplicates. PowerShell creates them because the names contain
:: $()' which CMD cannot pass through its own parser.
echo %M_INFO%step 3/4 . creating .up injection payloads ^(CVE-2024-8359^)
set "UPSCRIPT=%TEMP%\hud_up.ps1"
>  "!UPSCRIPT!" echo $ErrorActionPreference='Stop'
>> "!UPSCRIPT!" echo $d=$args[0]
>> "!UPSCRIPT!" echo $q=[char]39
>> "!UPSCRIPT!" echo $m='$^(' + 'awk -v f=%%c ' + $q + 'BEGIN{s=f f f f f f f f f f f f f f f f f f f;system^(sprintf^(s,115,104,32,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116^)^)}' + $q + '^).up'
>> "!UPSCRIPT!" echo $t='$^(' + 'awk -v f=%%c ' + $q + 'BEGIN{s=f f f f f f f f f f f f f f f f f f f f f f f;system^(sprintf^(s,115,104,32,47,116,109,112,47,109,110,116,47,115,100,91,97,98,99,100,93,49,47,116^)^)}' + $q + '^).up'
>> "!UPSCRIPT!" echo New-Item -ItemType File -Path ^(Join-Path $d $m^) -Force ^| Out-Null
>> "!UPSCRIPT!" echo New-Item -ItemType File -Path ^(Join-Path $d $t^) -Force ^| Out-Null
>> "!UPSCRIPT!" echo ^(Get-ChildItem -LiteralPath $d -Filter '*.up'^).Count
set "UPCOUNT=0"
:: Pass "!TARGET!"  WITHOUT a trailing backslash -- `"X:\"` is parsed by
:: Windows arg rules as `X:"` (the `\"` escapes the closing quote), which
:: PowerShell then rejects or misinterprets. Join-Path handles no-slash fine.
for /f %%u in ('powershell -NoProfile -ExecutionPolicy Bypass -File "!UPSCRIPT!" "!TARGET!"') do set "UPCOUNT=%%u"
del /q "!UPSCRIPT!" 2>nul
if !UPCOUNT! GEQ 2 (
  echo %M_OK%  !UPCOUNT! .up injection payloads present
) else (
  echo %M_ERR%  expected 2 .up payload files, found !UPCOUNT! -- auto-trigger will not work
  exit /b 1
)

:: --- MD5-verify every critical file on the stick (match toolkit.sh exactly) ---
echo %M_INFO%step 4/4 . verifying every critical file
set "VSCRIPT=%TEMP%\mzd_verify.ps1"
>  "!VSCRIPT!" echo $ErrorActionPreference='SilentlyContinue'
>> "!VSCRIPT!" echo $src=$args[0]; $dst=$args[1]; $problems=0
>> "!VSCRIPT!" echo $files=@('s','dev.html','mp3/a.mp3','mp3/b.mp3','mp3/c.mp3','mp3/d.mp3','a.mp3','b.mp3','c.mp3','d.mp3','js/run.js','js/enable_ssh.sh','css/init.css','jci-autoupdate','dataRetrieval_config.txt','tweaks.sh','t','h')
>> "!VSCRIPT!" echo foreach ($f in $files) {
>> "!VSCRIPT!" echo   $dstp=Join-Path $dst ($f -replace '/','\')
>> "!VSCRIPT!" echo   if (-not (Test-Path -LiteralPath $dstp)) { Write-Output ("  MISSING: " + $f); $problems++; continue }
>> "!VSCRIPT!" echo   if ($f -match '^[abcd]\.mp3$') { $srcp = Join-Path $src ("mp3\" + $f) } else { $srcp = Join-Path $src ($f -replace '/','\') }
>> "!VSCRIPT!" echo   if (-not (Test-Path -LiteralPath $srcp)) { continue }
>> "!VSCRIPT!" echo   $sh = (Get-FileHash -Algorithm MD5 -LiteralPath $srcp).Hash
>> "!VSCRIPT!" echo   $dh = (Get-FileHash -Algorithm MD5 -LiteralPath $dstp).Hash
>> "!VSCRIPT!" echo   if ($sh -ne $dh) { Write-Output ("  CORRUPT: " + $f + " (src=" + $sh.ToLower() + " dst=" + $dh.ToLower() + ")"); $problems++ }
>> "!VSCRIPT!" echo }
>> "!VSCRIPT!" echo $dsc = (Get-ChildItem -LiteralPath $dst -Recurse -Force -Filter '._*' -ErrorAction SilentlyContinue).Count
>> "!VSCRIPT!" echo if ($dsc -gt 0) { Write-Output ("  " + $dsc + " AppleDouble (._*) sidecars leaked -- would break the CMU"); $problems += $dsc }
>> "!VSCRIPT!" echo exit $problems
powershell -NoProfile -ExecutionPolicy Bypass -File "!VSCRIPT!" "%FILES%\usb_unlock" "!TARGET_BS!"
set "VRC=!errorlevel!"
del /q "!VSCRIPT!" 2>nul
if !VRC! GTR 0 (
  echo %M_ERR%!VRC! problem^(s^) above -- stick may not work. Re-run option 1.
  exit /b 1
)
echo %M_OK%all critical files present + byte-identical to source

:: Try to eject (PowerShell shell.application supports it from Win 10 onward)
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { (New-Object -comObject Shell.Application).Namespace(17).ParseName('!TARGET!').InvokeVerb('Eject') } catch {}" >nul 2>&1

echo.
echo %M_OK%USB ready. In the car:
echo %M_INFO%  1. Insert USB -^> wait ~30s -^> dialog with Install / Uninstall / Check.
echo %M_INFO%     ^(the .up injection triggers the firmware update scanner^)
echo %M_INFO%  2. If no dialog: Media -^> USB -^> tap any mp3 -^> XSS menu appears.
echo %M_INFO%     SSH   -- enable SSH for this toolkit
echo %M_INFO%     HUD+  -- install the CarPlay + Android Auto HUD patch
echo %M_INFO%     HUD-  -- remove it           HUD? -- check it is active
exit /b 0

:: ===========================================================================
:: 2) Backup CMU state
:: ===========================================================================
:backup
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Backup CMU state ^(before any mods^) ===

for /f %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%a"
if "!TS!"=="" (echo %M_ERR%could not get timestamp & exit /b 1)
set "DST=%DIR%backups\!TS!"
mkdir "!DST!" 2>nul
echo %M_INFO%backing up to !DST!

ssh %SSHOPTS% -p %PORT% %CMU% "tar -czf /tmp/backup.tar.gz /jci/sm/sm.conf /jci/sm/sm_WCP.conf /etc/devmgr_config_master.xml /jci/carplay/blmjcicarplay.so /jci/version.ini /data_persist/cp-hud-mod /data_persist/splim_udpd_start.sh /data_persist/splim 2>/dev/null; ls -la /tmp/backup.tar.gz"
if errorlevel 1 (echo %M_ERR%tar failed on CMU & exit /b 1)

scp %SSHOPTS% -P %PORT% %CMU%:/tmp/backup.tar.gz "!DST!\backup.tar.gz"
if errorlevel 1 (echo %M_ERR%scp of backup failed & exit /b 1)

ssh %SSHOPTS% -p %PORT% %CMU% "rm -f /tmp/backup.tar.gz" >nul 2>&1

for %%A in ("!DST!\backup.tar.gz") do set "SZ=%%~zA"
if "!SZ!"=="0" (echo %M_ERR%backup file is empty -- something went wrong & exit /b 1)
if "!SZ!"==""  (echo %M_ERR%backup file missing after copy & exit /b 1)
echo %M_OK%backup saved: !DST!\backup.tar.gz ^(!SZ! bytes^)
exit /b 0

:: ===========================================================================
:: 3) Full rollback (menu 3)  --  remove EVERY HUD patch, back to stock.
::    Uses the unified uninstall.sh (strips every libpatch LD_PRELOAD,
::    sets NaviSupported=FALSE, restores AA XMLs). Then removes v16 files
::    and reboots.
:: ===========================================================================
:rollback_all
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Rollback -- remove every HUD patch, back to stock ===
set "OK="
set /p "OK=This removes all HUD patches from the CMU and reboots. Continue? [y/N] > "
if /I not "!OK!"=="y" (echo cancelled & exit /b 0)
if not exist "%UNIFIED%\uninstall.sh" (echo %M_ERR%%UNIFIED%\uninstall.sh is missing -- re-download the toolkit & exit /b 1)

echo %M_INFO%1/3 . stopping the old speed daemon ^(v16^), if any
call :wipe_speed_mod

echo %M_INFO%2/3 . removing the patches
call :md5_local "%UNIFIED%\uninstall.sh"
set "PV_SRC=%UNIFIED%\uninstall.sh"
set "PV_DST=/tmp/hud-mod-uninstall.sh"
set "PV_WANT=!LMD5!"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- uninstall.sh did not land correctly & exit /b 1)
ssh %SSHOPTS% -p %PORT% %CMU% "sh /tmp/hud-mod-uninstall.sh; rm -rf /data_persist/cp-hud-mod /data_persist/splim_udpd_start.sh; sync"
echo %M_OK%removed -- rebooting the CMU
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

echo %M_INFO%3/3 . confirming after the reboot
call :wait_for_ssh
if errorlevel 1 exit /b 1
set "RB_OUT="
for /f "usebackq delims=" %%a in (`ssh %SSHOPTS% -p %PORT% %CMU% "echo $(cat /jci/sm/sm.conf /jci/sm/sm_WCP.conf 2>/dev/null | grep -c libpatch-) $(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml | grep -oE '[A-Z]+$')"`) do set "RB_OUT=%%a"
if "!RB_OUT!"=="0 FALSE" (
  echo %M_OK%back to stock: no patch preloads, NaviSupported=FALSE
) else (
  echo %M_WARN%unexpected state after rollback: '!RB_OUT!' -- run Advanced -^> D
)
exit /b 0

:: ===========================================================================
:: K) Rollback (KidMixer path) -- same end state as rollback_all, but the
::    older code path that uses KidMixer's uninstall.sh + force-cleaning.
:: ===========================================================================
:rollback
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Full rollback -- restore factory state ===

echo %M_INFO%1/3 . killing our speed daemon + wiping state
call :wipe_speed_mod

echo %M_INFO%2/3 . running KidMixer uninstall.sh
scp %SSHOPTS% -P %PORT% "%FILES%\uninstall.sh" %CMU%:/tmp/uninstall.sh
if errorlevel 1 (echo %M_ERR%scp uninstall.sh failed & exit /b 1)
ssh %SSHOPTS% -p %PORT% %CMU% "sh /tmp/uninstall.sh"

echo %M_INFO%3/3 . verifying + force-cleaning any residue
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null || true; for CONF in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do [ -f \"$CONF\" ] || continue; before=$(grep -c libpatch-blmjcicarplay \"$CONF\" 2>/dev/null); before=${before:-0}; if [ \"$before\" -gt 0 ]; then echo \"  ! $CONF still has $before LD_PRELOAD lines - force-stripping\"; grep -v libpatch-blmjcicarplay \"$CONF\" | grep -v 'LD_LIBRARY_PATH.*jci/lib:/usr/lib' > /tmp/rb.clean; cp /tmp/rb.clean \"$CONF\"; rm -f /tmp/rb.clean; sed -i '/name=\"jciCARPLAY\"/ s/reset_board=\"no\"/reset_board=\"yes\"/' \"$CONF\"; fi; done; if grep -q '<name>NaviSupported</name><value>TRUE</value>' /etc/devmgr_config_master.xml 2>/dev/null; then echo '  ! NaviSupported=TRUE - forcing to FALSE'; sed -i 's#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#' /etc/devmgr_config_master.xml; fi; rm -rf /data_persist/cp-hud-mod; sync; mount -o remount,ro / 2>/dev/null || true; echo \"  final: sm.conf preload=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null)  sm_WCP.conf preload=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null)  NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$')\""

echo %M_OK%rollback commands complete. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 exit /b 1
echo.
echo %M_INFO%confirming factory state...
ssh %SSHOPTS% -p %PORT% %CMU% "grep -c libpatch /jci/sm/sm.conf 2>/dev/null; grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null; grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$'"
echo %M_INFO%if you see: 0, 0, FALSE -- CMU is back to factory state
exit /b 0

:: ===========================================================================
:: 4) Install CarPlay + Android Auto HUD Patch (unified)
:: ===========================================================================
:install_unified
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Install CarPlay + Android Auto HUD Patch ^(one patch for both phones^) ===
echo %M_INFO%arrows + distance on the HUD for CarPlay AND Android Auto,
echo %M_INFO%speed-limit sign from the stock navigation for both ^(needs the nav SD card^).
echo %M_INFO%Replaces any earlier HUD patch; every edited file is backed up.
if not exist "%UNIFIED%\MD5SUMS" (echo %M_ERR%%UNIFIED% is missing -- re-download the toolkit & exit /b 1)
echo.
echo %M_INFO%1/3 . copying the package ^(md5-verified^)
ssh %SSHOPTS% -p %PORT% %CMU% "rm -rf %UNIFIED_REMOTE% && mkdir -p %UNIFIED_REMOTE%"
if errorlevel 1 (echo %M_ERR%cannot prepare %UNIFIED_REMOTE% on the CMU & exit /b 1)
set "UNIFIED_FAIL=0"
for %%F in ("%UNIFIED%\*") do (
  if /I not "%%~nxF"=="MD5SUMS" (
    call :md5_local "%%~fF"
    findstr /I /C:"%%~nxF" "%UNIFIED%\MD5SUMS" >nul
    if not errorlevel 1 (
      findstr /I /B /C:"!LMD5! %%~nxF" "%UNIFIED%\MD5SUMS" >nul
      if errorlevel 1 (echo %M_ERR%local file damaged: %%~nxF -- re-download the toolkit & set "UNIFIED_FAIL=1" & goto :install_unified_done)
    )
    set "PV_SRC=%%~fF"
    set "PV_DST=%UNIFIED_REMOTE%/%%~nxF"
    set "PV_WANT=!LMD5!"
    call :push_verify
    if errorlevel 1 (echo %M_ERR%aborted -- package did not land correctly, nothing was changed & set "UNIFIED_FAIL=1" & goto :install_unified_done)
  )
)
:install_unified_done
if "!UNIFIED_FAIL!"=="1" exit /b 1

echo %M_INFO%2/3 . running the installer on the CMU
set "INSTLOG=%TEMP%\hudmod_install.txt"
ssh %SSHOPTS% -p %PORT% %CMU% "cd %UNIFIED_REMOTE% && sh install.sh" > "!INSTLOG!" 2>&1
type "!INSTLOG!"
findstr /L /C:"DONE. Reboot" "!INSTLOG!" >nul
if errorlevel 1 (echo. & echo %M_ERR%the installer did not finish -- nothing to reboot for. The lines above say why. & exit /b 1)

:: Retire the old KidMixer speed daemon just in case
ssh %SSHOPTS% -p %PORT% %CMU% "for p in $(ps | grep '[s]plim_udpd' | awk '{print $1}'); do kill $p; done" >nul 2>&1

echo %M_OK%installed -- rebooting the CMU
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

echo %M_INFO%3/3 . after the reboot
call :wait_for_ssh
if errorlevel 1 exit /b 1
call :validate_unified
exit /b 0

:: ===========================================================================
:: L) Install ilshyma HUD Patch (v16 mod)
:: ===========================================================================
:install_mod
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Install ilshyma HUD Patch  * recommended ^(v16 - speed limit fixed^) ===

call :kidmixer_base
if errorlevel 1 (echo %M_ERR%aborted -- base install failed & exit /b 1)

echo %M_INFO%overlaying patched .so ^(v16^)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
set "PV_SRC=%FILES%\libpatch-blmjcicarplay-splim.so"
set "PV_DST=/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so"
set "PV_WANT=%MD5_SO_MOD%"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- v16 mod .so did not land correctly & exit /b 1)

echo %M_INFO%deploying speed-mirror daemon ^(v16^) + auto-launcher
:: Daemon is deployed AS splim_udpd (NO .sh) -- the shim looks it up via
:: `pgrep splim_udpd`, which matches argv[0]'s basename.
set "PV_SRC=%FILES%\splim_bridge.sh"
set "PV_DST=/data_persist/cp-hud-mod/splim_udpd"
set "PV_WANT=%MD5_SPLIM_BRIDGE%"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- daemon did not land correctly & exit /b 1)

set "PV_SRC=%FILES%\splim_udpd_start.sh"
set "PV_DST=/data_persist/splim_udpd_start.sh"
set "PV_WANT=%MD5_SPLIM_LAUNCHER%"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- launcher did not land correctly & exit /b 1)

:: Chmod + wipe stale splim from prior boot + drop old per-version debug logs + variant marker.
ssh %SSHOPTS% -p %PORT% %CMU% "chmod +x /data_persist/cp-hud-mod/splim_udpd /data_persist/splim_udpd_start.sh; rm -f /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/cp-hud-mod/splim_bridge_v*.sh; rm -f /mnt/data_persist/splim /data_persist/splim; rm -f /mnt/data_persist/log/splim_v5.log /mnt/data_persist/log/splim_v6.log /mnt/data_persist/log/splim_v7.log /mnt/data_persist/log/splim_v8.log /mnt/data_persist/log/splim_v9.log /mnt/data_persist/log/splim_v10.log /mnt/data_persist/log/splim_v11.log /mnt/data_persist/log/splim_v12.log /mnt/data_persist/log/splim_v13.log /mnt/data_persist/log/splim_v14.log /mnt/data_persist/log/splim_v15.log; echo v16 > /data_persist/cp-hud-mod/.variant"

echo %M_OK%install complete -- every file verified. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 exit /b 1
echo.
echo %M_INFO%running automatic post-install validation...
call :validate
exit /b 0

:: ===========================================================================
:: P) Install PURE KidMixer Patch
:: ===========================================================================
:install_pure
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Install PURE KidMixer Patch ^(known speed-limit issue^) ===

call :kidmixer_base
if errorlevel 1 (echo %M_ERR%aborted -- base install failed & exit /b 1)

echo %M_INFO%overlaying pure .so ^(in case a mod .so was on disk^)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
set "PV_SRC=%FILES%\libpatch-blmjcicarplay.so"
set "PV_DST=/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so"
set "PV_WANT=%MD5_SO_PURE%"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- pure .so did not land correctly & exit /b 1)

echo %M_INFO%clearing any prior speed-mod daemon + state
call :wipe_speed_mod
ssh %SSHOPTS% -p %PORT% %CMU% "echo pure > /data_persist/cp-hud-mod/.variant" >nul 2>&1

echo %M_OK%pure KidMixer installed. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 exit /b 1
echo.
echo %M_INFO%running automatic post-install validation...
call :validate
exit /b 0

:: ===========================================================================
:: X) Install ilshyma HUD Patch -- LEGACY mod .so (pre-v16)
:: ===========================================================================
:install_mod_legacy
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Install ilshyma HUD Patch -- LEGACY pre-v16 mod .so ===

call :kidmixer_base
if errorlevel 1 (echo %M_ERR%aborted -- base install failed & exit /b 1)

echo %M_INFO%overlaying LEGACY .so ^(pre-v16, md5 %MD5_SO_MOD_LEGACY%^)
ssh %SSHOPTS% -p %PORT% %CMU% "mount -o remount,rw / 2>/dev/null; true"
set "PV_SRC=%FILES%\libpatch-blmjcicarplay-splim-legacy.so"
set "PV_DST=/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so"
set "PV_WANT=%MD5_SO_MOD_LEGACY%"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- legacy .so did not land correctly & exit /b 1)

echo %M_INFO%deploying speed-mirror daemon ^(v16^) + auto-launcher
set "PV_SRC=%FILES%\splim_bridge.sh"
set "PV_DST=/data_persist/cp-hud-mod/splim_udpd"
set "PV_WANT=%MD5_SPLIM_BRIDGE%"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- daemon did not land correctly & exit /b 1)

set "PV_SRC=%FILES%\splim_udpd_start.sh"
set "PV_DST=/data_persist/splim_udpd_start.sh"
set "PV_WANT=%MD5_SPLIM_LAUNCHER%"
call :push_verify
if errorlevel 1 (echo %M_ERR%aborted -- launcher did not land correctly & exit /b 1)

ssh %SSHOPTS% -p %PORT% %CMU% "chmod +x /data_persist/cp-hud-mod/splim_udpd /data_persist/splim_udpd_start.sh; rm -f /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/cp-hud-mod/splim_bridge_v*.sh; rm -f /mnt/data_persist/splim /data_persist/splim; echo legacy > /data_persist/cp-hud-mod/.variant"

echo %M_OK%legacy mod installed. Rebooting...
ssh %SSHOPTS% -p %PORT% %CMU% "sync && reboot" >nul 2>&1

call :wait_for_ssh
if errorlevel 1 exit /b 1
echo.
echo %M_INFO%running automatic post-install validation...
call :validate
exit /b 0

:: ===========================================================================
:: Validate installation  --  routes to validate_unified when oem-aa-mod is
::  present, otherwise does the classic KidMixer/v16 chain validation with
::  auto-fix of the speed daemon (up to 3 tries).
:: ===========================================================================
:validate
call :check_conn
if errorlevel 1 exit /b 1
:: Route to unified validation when the unified patch is installed
ssh %SSHOPTS% -p %PORT% %CMU% "[ -f /data_persist/oem-aa-mod/libpatch-svcjcinavi.so ] && grep -q 'oem-aa-mod/libpatch-blmjcicarplay' /jci/sm/sm.conf /jci/sm/sm_WCP.conf" >nul 2>&1
if not errorlevel 1 (call :validate_unified & exit /b !errorlevel!)

echo.
echo === Validate installation ===
mkdir "%DIR%logs" 2>nul
for /f %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%a"
set "LOGFILE=%DIR%logs\validate_!TS!.log"

echo %M_INFO%collecting diagnostics from CMU ^(waiting 5s for services to settle^)...
timeout /t 5 /nobreak >nul

set "VOUT=%TEMP%\mzd_validate.txt"
del /q "%VOUT%" 2>nul
ssh %SSHOPTS% -p %PORT% %CMU% "echo PRELOAD_SM=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null || echo 0); echo PRELOAD_WCP=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null || echo 0); echo NAVISUPPORTED=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$'); P=$(ps | awk '/[L]_jciCARPLAY/{print $1; exit}'); echo CARPLAY_PID=${P:-0}; if [ -n \"$P\" ]; then echo CARPLAY_LOADED=$(tr '\0' '\n' < /proc/$P/maps 2>/dev/null | grep -c libpatch-blmjcicarplay); else echo CARPLAY_LOADED=0; fi; echo SO_MD5=$(md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so 2>/dev/null | awk '{print $1}'); echo VARIANT=$(cat /data_persist/cp-hud-mod/.variant 2>/dev/null); echo DAEMON_COUNT=$(ps | grep -v grep | grep -cE 'splim_udpd|splim_bridge'); echo LAUNCHER_OK=$([ -x /data_persist/splim_udpd_start.sh ] && echo 1 || echo 0); echo DAEMON_BIN_OK=$([ -x /data_persist/cp-hud-mod/splim_udpd ] && echo 1 || echo 0); SF=''; [ -e /mnt/data_persist/splim ] && SF=$(cat /mnt/data_persist/splim 2>/dev/null); [ -z \"$SF\" ] && [ -e /data_persist/splim ] && SF=$(cat /data_persist/splim 2>/dev/null); echo SPLIM_CONTENT=$SF; echo CLOCK=$(date)" > "%VOUT%" 2>&1
copy "%VOUT%" "!LOGFILE!" >nul 2>&1

set "PROBLEMS=0"
for /f "usebackq tokens=1,* delims==" %%a in ("%VOUT%") do (
  if /I "%%a"=="PRELOAD_SM"     set "V_PRELOAD_SM=%%b"
  if /I "%%a"=="PRELOAD_WCP"    set "V_PRELOAD_WCP=%%b"
  if /I "%%a"=="NAVISUPPORTED"  set "V_NAVI=%%b"
  if /I "%%a"=="CARPLAY_PID"    set "V_PID=%%b"
  if /I "%%a"=="CARPLAY_LOADED" set "V_LOADED=%%b"
  if /I "%%a"=="SO_MD5"         set "V_SO=%%b"
  if /I "%%a"=="VARIANT"        set "V_VARIANT=%%b"
  if /I "%%a"=="DAEMON_COUNT"   set "V_DAEMON=%%b"
  if /I "%%a"=="LAUNCHER_OK"    set "V_LNC=%%b"
  if /I "%%a"=="DAEMON_BIN_OK"  set "V_BIN=%%b"
  if /I "%%a"=="SPLIM_CONTENT"  set "V_SPLIM=%%b"
)
del /q "%VOUT%" 2>nul

if not defined V_PRELOAD_SM   set "V_PRELOAD_SM=0"
if not defined V_PRELOAD_WCP  set "V_PRELOAD_WCP=0"
if not defined V_DAEMON       set "V_DAEMON=0"
if not defined V_LOADED       set "V_LOADED=0"
if not defined V_PID          set "V_PID=0"

echo.
:: 1. LD_PRELOAD
set "LD_OK=0"
if !V_PRELOAD_SM!  GTR 0 set "LD_OK=1"
if !V_PRELOAD_WCP! GTR 0 set "LD_OK=1"
if "!LD_OK!"=="1" (
  echo %M_OK%LD_PRELOAD wired  ^(sm.conf=!V_PRELOAD_SM!  sm_WCP.conf=!V_PRELOAD_WCP!^)
) else (
  echo %M_ERR%LD_PRELOAD missing from both configs -- install did not take
  set /a PROBLEMS+=1
)

:: 2. NaviSupported
if /I "!V_NAVI!"=="TRUE" (
  echo %M_OK%NaviSupported=TRUE
) else (
  echo %M_ERR%NaviSupported=!V_NAVI! ^(expected TRUE^)
  set /a PROBLEMS+=1
)

:: 3. jciCARPLAY + shim loaded
if not "!V_PID!"=="0" (
  if !V_LOADED! GTR 0 (
    echo %M_OK%jciCARPLAY running ^(pid=!V_PID!^) with our shim loaded
  ) else (
    echo %M_ERR%jciCARPLAY running ^(pid=!V_PID!^) but shim NOT loaded -- try another reboot
    set /a PROBLEMS+=1
  )
) else (
  echo %M_ERR%jciCARPLAY is not running
  set /a PROBLEMS+=1
)

:: 4. .so identity on disk
if /I "!V_SO!"=="%MD5_SO_MOD%" (
  echo %M_OK%mod .so on disk: v16 ^(speed-limit patch^)
) else if /I "!V_SO!"=="%MD5_SO_MOD_LEGACY%" (
  echo %M_OK%mod .so on disk: legacy pre-v16 ^(speed-limit patch^)
) else if /I "!V_SO!"=="%MD5_SO_PURE%" (
  echo %M_WARN%PURE KidMixer .so on disk -- no speed-limit patch ^(normal for menu P^)
) else if "!V_SO!"=="" (
  echo %M_ERR%no .so found on disk at /data_persist/cp-hud-mod/
  set /a PROBLEMS+=1
) else (
  echo %M_WARN%unrecognized .so md5 on disk: !V_SO!
)

:: 5. speed daemon  (skip if variant=pure)
:: Labels inside ()-blocks are UB in cmd, so the retry loop lives in :validate_autofix.
if /I "!V_VARIANT!"=="pure" (
  echo %M_INFO%PURE variant installed -- no speed daemon expected
) else if !V_DAEMON! GTR 0 (
  echo %M_OK%speed-mirror daemon is running ^(!V_DAEMON! process^(es^)^)
) else (
  echo %M_WARN%speed-mirror daemon is NOT running -- attempting auto-start
  if not "!V_BIN!"=="1" (
    echo %M_ERR%  daemon binary missing -- re-run menu 4 or L
    set /a PROBLEMS+=1
  ) else if not "!V_LNC!"=="1" (
    echo %M_ERR%  launcher missing -- re-run menu 4 or L
    set /a PROBLEMS+=1
  ) else (
    call :validate_autofix
    if "!V_FIX_OK!"=="1" (
      echo %M_OK%  auto-fix worked -- daemon is now running ^(attempt !V_FIX_TRY!/3^)
    ) else (
      echo %M_ERR%  auto-fix FAILED after 3 attempts -- daemon still not running
      echo %M_ERR%  this is critical: the speed-limit slot will stay at --- until fixed
      echo. >> "!LOGFILE!"
      echo === auto-fix failure diagnostics === >> "!LOGFILE!"
      ssh %SSHOPTS% -p %PORT% %CMU% "uptime; echo; echo '-- launcher stderr --'; cat /tmp/splim_launcher.log 2>/dev/null; echo; echo '-- full ps --'; ps" >> "!LOGFILE!" 2>&1
      echo %M_ERR%  full diagnostic saved: !LOGFILE!
      echo %M_ERR%  try Advanced -^> D ^(dump^) or Advanced -^> F ^(force-start^)
      set /a PROBLEMS+=1
    )
  )
)

:: 6. splim data file (informational)
:: `set "X=" ` UNDEFINES X, so `if defined` would skip us when SPLIM is empty.
:: Testing `!X!=="" `  with delayed expansion catches both undefined and empty.
if "!V_SPLIM!"=="" (
  echo %M_INFO%speed-limit file is empty -- normal right after install; fills in once you drive past a sign
) else (
  echo %M_INFO%speed-limit file currently holds: !V_SPLIM! ^(updates live while driving^)
)

echo.
if !PROBLEMS!==0 (
  echo %M_OK%============ VALIDATION PASSED ============
  echo       HUD arrows ready; speed limit will populate while driving
  echo       log: !LOGFILE!
) else (
  echo %M_ERR%============ VALIDATION FOUND !PROBLEMS! PROBLEM^(S^) ============
  echo       full diagnostic saved: !LOGFILE!
  echo       Advanced -^> D = verbose dump    Advanced -^> F = retry starting daemon
)
exit /b 0

:: ===========================================================================
:: :validate_autofix -- retry starting the speed daemon up to 3 times.
:: Returns V_FIX_OK=1 if it comes up, 0 otherwise, plus V_FIX_TRY = attempt
:: count. A dropped SSH link returns garbage, not a bare "0" -- so we
:: sanitize the recheck answer to a clean digit before comparing.
:: ===========================================================================
:validate_autofix
set "V_FIX_OK=0"
set /a V_FIX_TRY=0
:validate_autofix_loop
set /a V_FIX_TRY+=1
if !V_FIX_TRY! GTR 1 echo %M_WARN%  retry !V_FIX_TRY!/3 ^(link may have dropped mid-command^)...
call :force_start_quiet
timeout /t 3 /nobreak >nul
set "V_RECHECK=0"
for /f "usebackq" %%a in (`ssh %SSHOPTS% -p %PORT% %CMU% "ps | grep -v grep | grep -cE 'splim_udpd|splim_bridge'"`) do set "V_RECHECK=%%a"
set "V_RECHECK_OK=1"
for /f "delims=0123456789" %%z in ("!V_RECHECK!") do set "V_RECHECK_OK=0"
if "!V_RECHECK_OK!"=="0" set "V_RECHECK=0"
if !V_RECHECK! GTR 0 (set "V_FIX_OK=1" & exit /b 0)
if !V_FIX_TRY! LSS 3 goto validate_autofix_loop
exit /b 1

:: ===========================================================================
:: validate_unified  --  inline check of the 4 shims, same approach as the .sh
:: (no reliance on usb_run.sh being present on the CMU after install).
:: ===========================================================================
:validate_unified
echo.
echo === Validate CarPlay + Android Auto patch ===
echo %M_INFO%waiting 5s for services to settle...
timeout /t 5 /nobreak >nul

set "VUOUT=%TEMP%\mzd_val_unified.txt"
del /q "%VUOUT%" 2>nul
:: Inside double-quoted ssh arg: &, |, (, ) are literal (CMD does not parse
:: them inside quotes). Do NOT use `^&^&` here -- the `^` would reach the
:: remote shell verbatim and corrupt the awk expression.
ssh %SSHOPTS% -p %PORT% %CMU% "pid_of() { ps | awk -v p=\"$1\" 'index($0, p) && !/awk/ { print $1; exit }'; }; for pair in L_jciCARPLAY:blmjcicarplay L_jciAAPA:blmjciaapa L_jcinavi:svcjcinavi /usr/bin/aap_service:aap_service; do svc=${pair%%%%:*}; so=${pair##*:}; pid=$(pid_of \"$svc\"); if [ -z \"$pid\" ]; then echo \"MISS $svc not running\"; elif grep -q \"libpatch-$so.so\" /proc/$pid/maps 2>/dev/null; then echo \"OK   $svc pid=$pid has libpatch-$so.so\"; else echo \"FAIL $svc pid=$pid does NOT have libpatch-$so.so\"; fi; done; echo \"INFO NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml | grep -oE '[A-Z]+$')\"; echo \"INFO config: $(grep -E '^(hud_transport|force_street_name|force_street_name_native|use_protocol_v1_6)' /data_persist/oem-aa-mod/libpatch.conf | tr '\n' ' ')\"; echo \"INFO stock-nav speed shared with CarPlay: $(cat /tmp/hud_oem_speed 2>/dev/null || echo 'none yet (appears with the first stock-nav HUD frame)')\"" > "!VUOUT!" 2>&1

set "VU_PROBLEMS=0"
set "VU_OK_SEEN=0"
for /f "usebackq delims=" %%L in ("!VUOUT!") do (
  set "LN=%%L"
  if "!LN:~0,2!"=="OK"   (echo %M_OK%!LN:~5! & set "VU_OK_SEEN=1")
  if "!LN:~0,4!"=="FAIL" (echo %M_ERR%!LN:~5! & set /a VU_PROBLEMS+=1)
  if "!LN:~0,4!"=="MISS" (echo %M_WARN%!LN:~5! & set /a VU_PROBLEMS+=1)
  if "!LN:~0,4!"=="INFO" (echo %M_INFO%!LN:~5!)
)
del /q "!VUOUT!" 2>nul
echo.
if !VU_PROBLEMS!==0 if "!VU_OK_SEEN!"=="1" (
  echo %M_OK%all 4 shims loaded -- start a CarPlay or Android Auto route and watch the HUD
  exit /b 0
)
echo %M_ERR%!VU_PROBLEMS! of 4 services not running or without their shim
echo %M_ERR%wait a minute and re-run Advanced -^> V; if it stays, run Advanced -^> D
exit /b 1

:: ===========================================================================
:: F) Force-start speed daemon
:: ===========================================================================
:force_start_quiet
:: `&` inside double quotes is literal to CMD, so it reaches the remote shell
:: as a plain `&` -- which is what we need there to background nohup. Do NOT
:: write `^&` here; the `^` would arrive verbatim and bash would treat it as
:: an extra argument to nohup, so the daemon never gets backgrounded.
ssh %SSHOPTS% -p %PORT% %CMU% "pkill -9 splim_bridge 2>/dev/null; kill -9 $(pgrep splim_udpd) 2>/dev/null; rm -f /mnt/data_persist/splim /data_persist/splim; sleep 1; nohup /data_persist/splim_udpd_start.sh >/tmp/splim_launcher.log 2>&1 &" >nul 2>&1
exit /b 0

:force_start_daemon
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Force-restart speed-mirror daemon ===
ssh %SSHOPTS% -p %PORT% %CMU% "echo '--- killing anything old ---'; pkill -9 splim_bridge 2>/dev/null; pkill -9 splim_udpd 2>/dev/null; kill -9 $(pgrep splim_udpd) 2>/dev/null; sleep 1; echo '--- clearing stale splim file ---'; rm -f /mnt/data_persist/splim /data_persist/splim /tmp/splim_v*_last /tmp/splim_v*_cache; rm -rf /tmp/splim_v*_cache; echo '--- starting via launcher ---'; if [ ! -x /data_persist/splim_udpd_start.sh ]; then echo '  ! launcher missing -- install first (menu 4)'; exit 1; fi; if [ ! -x /data_persist/cp-hud-mod/splim_udpd ]; then echo '  ! daemon binary missing -- install first (menu 4 or X)'; exit 1; fi; nohup /data_persist/splim_udpd_start.sh >/tmp/splim_launcher.log 2>&1 & sleep 3; echo '--- after 3s ---'; DP=$(ps | grep -v grep | grep -E 'splim_bridge|splim_udpd|dbus-monitor'); if [ -n \"$DP\" ]; then echo \"$DP\" | sed 's/^/  /'; else echo '  ! still no processes running'; fi; echo '  launcher stderr:'; tail -20 /tmp/splim_launcher.log 2>/dev/null | sed 's/^/    /'"
echo.
echo %M_INFO%now start CarPlay navigation and use Advanced -^> T ^(live tail^).
echo %M_INFO%you should see 'got splim=NN unit=2' lines each time a sign is captured.
exit /b 0

:: ===========================================================================
:: D) Diagnose  --  verbose dump of every piece of the mod chain
:: ===========================================================================
:diagnose
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Diagnose speed-limit chain ^(verbose^) ===
ssh %SSHOPTS% -p %PORT% %CMU% "echo; echo '--- 1. LD_PRELOAD wiring ---'; grep -c libpatch /jci/sm/sm.conf 2>/dev/null | awk '{print \"  sm.conf preload lines: \"$0}'; grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null | awk '{print \"  sm_WCP.conf preload lines: \"$0}'; grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | tr -d '<>' | awk '{print \"  \"$0}'; echo; echo '--- 2. jciCARPLAY process ---'; P=$(ps | awk '/[L]_jciCARPLAY/{print $1; exit}'); if [ -n \"$P\" ]; then echo \"  pid=$P\"; tr '\0' '\n' < /proc/$P/maps 2>/dev/null | grep -o libpatch-blmjcicarplay | head -1 | awk '{print \"  loaded: \"$0}'; tr '\0' '\n' < /proc/$P/environ 2>/dev/null | grep LD_PRELOAD | awk '{print \"  \"$0}'; else echo '  ! jciCARPLAY not running'; fi; echo; echo '--- 3. .so on disk + variant ---'; md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so 2>/dev/null | awk '{print \"  \"$0}'; echo \"  variant marker: $(cat /data_persist/cp-hud-mod/.variant 2>/dev/null || echo '(none)')\"; echo; echo '--- 4. speed daemon ---'; DP=$(ps | grep -v grep | grep -E 'splim_bridge|splim_udpd|dbus-monitor'); if [ -n \"$DP\" ]; then echo \"$DP\" | awk '{print \"  \"$0}'; else echo '  ! no splim processes running'; fi; echo; echo '--- 5. splim file ---'; for P in /mnt/data_persist/splim /data_persist/splim; do if [ -e \"$P\" ]; then printf '  %%s -> ' \"$P\"; ls -la \"$P\" | awk '{print $5\" bytes, mtime \"$6\" \"$7\" \"$8}'; printf '    content: '; cat \"$P\" 2>/dev/null; echo; else echo \"  $P -> does not exist\"; fi; done; echo; echo '--- 6. auto-launcher ---'; ls -la /data_persist/splim_udpd_start.sh 2>/dev/null | awk '{print \"  \"$0}'; [ -f /data_persist/splim_udpd_start.sh ] || echo '  ! launcher missing'; echo; echo '--- 7. daemon log ---'; L=$(ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1); if [ -n \"$L\" ]; then echo \"  $L:\"; tail -15 \"$L\" | sed 's/^/    /'; else echo '  ! no splim_v*.log found'; fi; echo; echo '--- 8. RTC ---'; date | awk '{print \"  \"$0}'"
exit /b 0

:: ===========================================================================
:: T) Live-tail speed-daemon log
:: ===========================================================================
:tail_log
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === Live tail speed-daemon log ^(Ctrl+C to exit^) ===
ssh %SSHOPTS% -p %PORT% %CMU% "ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1 | xargs -r tail -F 2>/dev/null"
exit /b 0

:: ===========================================================================
:: C) CarPlay HUD arrow debug log  (/tmp/carplay_bridge.log on the CMU)
:: ===========================================================================
:carplay_log
call :check_conn
if errorlevel 1 exit /b 1
echo.
echo === CarPlay HUD arrow debug log ^(/tmp/carplay_bridge.log^) ===
ssh %SSHOPTS% -p %PORT% %CMU% "if [ ! -s /tmp/carplay_bridge.log ]; then echo '  (empty or missing -- either no CarPlay nav session has run yet this boot, or this .so build does not emit debug output)'; exit 0; fi; echo \"  size: $(wc -c < /tmp/carplay_bridge.log) bytes\"; echo; echo '  distinct maneuver/street lines seen:'; grep -iE 'maneuver|street|distance|nextManeuver' /tmp/carplay_bridge.log 2>/dev/null | sort -u | sed 's/^/    /' | head -30; echo; echo '  any send/clear failures (rc!=0):'; grep -iE 'failed rc=|exception swallowed|conn_create failed|conn_connect failed' /tmp/carplay_bridge.log 2>/dev/null | sed 's/^/    /' | head -20; echo; echo '  last 30 lines:'; tail -30 /tmp/carplay_bridge.log | sed 's/^/    /'"
exit /b 0
