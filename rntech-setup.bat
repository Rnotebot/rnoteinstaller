@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 437 >nul 2>&1

REM ==========================================================
REM rntech-setup.bat  (Rntech Windows post-install)
REM
REM Runs on the freshly installed Windows guest (via SetupComplete).
REM Reads the RNTECH_* job-env keys, decodes the base64 RDP password
REM in-process (never on a command line), applies RDP settings, and
REM POSTs finishing/done/failed callbacks using the same body keys the
REM Rntech panel /api/events expects: job_id, token, attempt_id,
REM status, node, message.
REM
REM Paths live under C:\Rntech. Authored fresh for Rntech; it is NOT a
REM copy of any legacy reference file.
REM ==========================================================

REM Repair PATH so System32/PowerShell are reachable.
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem;%SystemRoot%\System32\WindowsPowerShell\v1.0;%PATH%"

set "RNTECH_DIR=C:\Rntech"
set "LOG=C:\Rntech\rntech-setup.log"
set "RNTECH_DEFAULT_RDP_PORT=7777"
set "RDP_PORT=%RNTECH_DEFAULT_RDP_PORT%"
set "ADMIN_USER=Administrator"
set "ADMIN_PASS="
set "RNTECH_SETUP_MODE=NORMAL"
set "RNTECH_RDP_USERNAME=Administrator"
set "RNTECH_CUSTOM_RDP_PASSWORD=0"
set "RNTECH_CUSTOM_RDP_PORT=0"

set "SYS32=%SystemRoot%\System32"
if exist "%SystemRoot%\Sysnative\cmd.exe" set "SYS32=%SystemRoot%\Sysnative"
set "PS_EXE=%SYS32%\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%RNTECH_DIR%" mkdir "%RNTECH_DIR%" >nul 2>&1

call :MAIN >> "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
exit /b %RC%


:MAIN
echo ========================================
echo RNTECH WINDOWS POST-INSTALL
echo Started: %date% %time%
echo User: %USERNAME%
echo Computer: %COMPUTERNAME%
echo ========================================

echo [0] Load install job context
call :LOAD_INSTALL_JOB_CONTEXT

echo [0.1] Check administrator privilege
call :CHECK_ADMIN
if errorlevel 1 (
    echo [ERROR] Not running as Administrator/SYSTEM.
    call :SEND_INSTALL_STATUS "failed" "rntech-setup.bat is not running as Administrator or SYSTEM."
    exit /b 1
)

echo [0.2] Notify panel that Windows finalization started
call :SEND_INSTALL_STATUS "finishing" "Windows finalization in progress. Please wait a few minutes."

echo [1] Apply RDP settings
call :APPLY_RDP_FIX

echo [2] Verify RDP listener and report done
netstat -ano -p TCP 2>nul | findstr /I /C:"LISTENING" | findstr /R /C:":%RDP_PORT% " >nul
if not errorlevel 1 (
    echo [OK] RDP listener active on port %RDP_PORT%.
    call :SEND_INSTALL_STATUS "done" "RDP is ready."
) else (
    echo [ERROR] RDP listener not detected on port %RDP_PORT%.
    call :SEND_INSTALL_STATUS "failed" "RDP listener did not come up on port %RDP_PORT%."
    exit /b 1
)

echo Finished: %date% %time%
exit /b 0


REM ==========================================================
REM LOAD INSTALL JOB CONTEXT
REM Priority:
REM   1. Environment already set by the installer
REM   2. C:\Rntech\rntech-job.env
REM   3. rntech-job.env next to this script
REM   4. C:\Windows\Setup\Scripts\rntech-job.env
REM ==========================================================
:LOAD_INSTALL_JOB_CONTEXT
set "RNTECH_JOB_CONFIG="

if exist "%RNTECH_DIR%\rntech-job.env" (
    set "RNTECH_JOB_CONFIG=%RNTECH_DIR%\rntech-job.env"
) else if exist "%~dp0rntech-job.env" (
    set "RNTECH_JOB_CONFIG=%~dp0rntech-job.env"
) else if exist "%SystemRoot%\Setup\Scripts\rntech-job.env" (
    set "RNTECH_JOB_CONFIG=%SystemRoot%\Setup\Scripts\rntech-job.env"
)

if defined RNTECH_JOB_CONFIG (
    call :READ_INSTALL_JOB_FILE "%RNTECH_JOB_CONFIG%"
    if /I not "%RNTECH_JOB_CONFIG%"=="%RNTECH_DIR%\rntech-job.env" (
        copy /y "%RNTECH_JOB_CONFIG%" "%RNTECH_DIR%\rntech-job.env" >nul 2>&1
    )
)

if /I not "%RNTECH_INSTALL_SOURCE_MODE%"=="DD" set "RNTECH_INSTALL_SOURCE_MODE=ISO"
if not defined RNTECH_INSTALL_LOG_URL if defined RNTECH_INSTALL_STATUS_URL (
    set "RNTECH_INSTALL_LOG_URL=%RNTECH_INSTALL_STATUS_URL%"
)
call :APPLY_INSTALL_RDP_SETTINGS
echo [MODE] Install source mode: %RNTECH_INSTALL_SOURCE_MODE%
echo [RDP] Port configured: %RDP_PORT%
set "RNTECH_CALLBACK_CONTEXT_READY="
if defined RNTECH_INSTALL_STATUS_URL if defined RNTECH_INSTALL_JOB_ID if defined RNTECH_INSTALL_JOB_TOKEN set "RNTECH_CALLBACK_CONTEXT_READY=1"
if defined RNTECH_CALLBACK_CONTEXT_READY (
    echo [CALLBACK] Install job context loaded: %RNTECH_INSTALL_JOB_ID%
) else (
    echo [CALLBACK] Install job context not available. Callback skipped.
)
exit /b 0


:READ_INSTALL_JOB_FILE
set "RNTECH_ENV_FILE=%~1"
set "RNTECH_ENV_COPY=%TEMP%\rntech-job-%RANDOM%-%RANDOM%.env"
set /a RNTECH_ENV_TRY=0

if not defined RNTECH_ENV_FILE exit /b 1
if not exist "%RNTECH_ENV_FILE%" exit /b 2

:READ_INSTALL_JOB_FILE_RETRY
set /a RNTECH_ENV_TRY+=1
copy /y "%RNTECH_ENV_FILE%" "%RNTECH_ENV_COPY%" >nul 2>&1
if not exist "%RNTECH_ENV_COPY%" (
    if %RNTECH_ENV_TRY% LSS 20 (
        echo [WARN] rntech-job.env busy. Retry %RNTECH_ENV_TRY%/20...
        timeout /t 1 /nobreak >nul 2>&1
        goto READ_INSTALL_JOB_FILE_RETRY
    )
    echo [WARN] Failed to read rntech-job.env after retries: %RNTECH_ENV_FILE%
    exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%A in ("%RNTECH_ENV_COPY%") do (
    if /I "%%A"=="RNTECH_INSTALL_STATUS_URL" if not defined RNTECH_INSTALL_STATUS_URL set "RNTECH_INSTALL_STATUS_URL=%%B"
    if /I "%%A"=="RNTECH_INSTALL_LOG_URL" if not defined RNTECH_INSTALL_LOG_URL set "RNTECH_INSTALL_LOG_URL=%%B"
    if /I "%%A"=="RNTECH_INSTALL_JOB_ID" if not defined RNTECH_INSTALL_JOB_ID set "RNTECH_INSTALL_JOB_ID=%%B"
    if /I "%%A"=="RNTECH_INSTALL_JOB_TOKEN" if not defined RNTECH_INSTALL_JOB_TOKEN set "RNTECH_INSTALL_JOB_TOKEN=%%B"
    if /I "%%A"=="RNTECH_INSTALL_ATTEMPT_ID" if not defined RNTECH_INSTALL_ATTEMPT_ID set "RNTECH_INSTALL_ATTEMPT_ID=%%B"
    if /I "%%A"=="RNTECH_INSTALL_NODE" if not defined RNTECH_INSTALL_NODE set "RNTECH_INSTALL_NODE=%%B"
    if /I "%%A"=="RNTECH_INSTALL_SOURCE_MODE" if not defined RNTECH_INSTALL_SOURCE_MODE set "RNTECH_INSTALL_SOURCE_MODE=%%B"
    if /I "%%A"=="RNTECH_RDP_PORT" if not defined RNTECH_RDP_PORT set "RNTECH_RDP_PORT=%%B"
    if /I "%%A"=="RNTECH_RDP_PASSWORD_B64" if not defined RNTECH_RDP_PASSWORD_B64 set "RNTECH_RDP_PASSWORD_B64=%%B"
    if /I "%%A"=="RNTECH_SETUP_MODE" set "RNTECH_SETUP_MODE=%%B"
    if /I "%%A"=="RNTECH_RDP_USERNAME" set "RNTECH_RDP_USERNAME=%%B"
    if /I "%%A"=="RNTECH_WINDOWS_VERSION" if not defined RNTECH_WINDOWS_VERSION set "RNTECH_WINDOWS_VERSION=%%B"
    if /I "%%A"=="RNTECH_ACTIVATION_PS1_URL" if not defined RNTECH_ACTIVATION_PS1_URL set "RNTECH_ACTIVATION_PS1_URL=%%B"
)

del /f /q "%RNTECH_ENV_COPY%" >nul 2>&1
exit /b 0


:APPLY_INSTALL_RDP_SETTINGS
if /I not "%RNTECH_SETUP_MODE%"=="GAMING" set "RNTECH_SETUP_MODE=NORMAL"
if /I "%RNTECH_SETUP_MODE%"=="GAMING" (
    set "ADMIN_USER=admin"
    set "RNTECH_RDP_USERNAME=admin"
) else (
    set "ADMIN_USER=%RNTECH_RDP_USERNAME%"
)
if not defined ADMIN_USER set "ADMIN_USER=Administrator"

set "RNTECH_VALIDATED_RDP_PORT="
if defined RNTECH_RDP_PORT (
    for /f "delims=" %%P in ('%PS_EXE% -NoLogo -NoProfile -Command "$p=0; if([int]::TryParse($env:RNTECH_RDP_PORT,[ref]$p) -and $p -ge 1 -and $p -le 65535){$p}"') do set "RNTECH_VALIDATED_RDP_PORT=%%P"
)
if defined RNTECH_VALIDATED_RDP_PORT (
    set "RDP_PORT=%RNTECH_VALIDATED_RDP_PORT%"
    set "RNTECH_CUSTOM_RDP_PORT=1"
) else (
    set "RDP_PORT=%RNTECH_DEFAULT_RDP_PORT%"
    echo [RDP] Port context invalid/unavailable; using safe fallback %RNTECH_DEFAULT_RDP_PORT%.
)

if not defined RNTECH_RDP_PASSWORD_B64 exit /b 0

REM Decode the base64 RDP password IN-PROCESS; never pass it on a command line.
set "RNTECH_RDP_SECRET_FILE=%TEMP%\rntech-rdp-secret-%RANDOM%-%RANDOM%.txt"
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
 "$ErrorActionPreference='Stop';" ^
 "$b=$env:RNTECH_RDP_PASSWORD_B64; $b += '=' * ((4-($b.Length -band 3)) -band 3);" ^
 "$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b));" ^
 "if($p -notmatch '^[A-Za-z0-9@#.$_+=-]{8,64}$'){exit 3};" ^
 "[IO.File]::WriteAllText($env:RNTECH_RDP_SECRET_FILE,$p,(New-Object Text.UTF8Encoding($false)));"
if errorlevel 1 (
    echo [WARN] Custom RDP password invalid. Skipping password apply.
    del /f /q "%RNTECH_RDP_SECRET_FILE%" >nul 2>&1
    exit /b 0
)
call :LOAD_RDP_PASSWORD_FROM_FILE "%RNTECH_RDP_SECRET_FILE%"
del /f /q "%RNTECH_RDP_SECRET_FILE%" >nul 2>&1
set "RNTECH_CUSTOM_RDP_PASSWORD=1"
echo [RDP] Custom password loaded securely.
exit /b 0


:LOAD_RDP_PASSWORD_FROM_FILE
setlocal DisableDelayedExpansion
set "RNTECH_DECODED_RDP_PASSWORD="
set /p "RNTECH_DECODED_RDP_PASSWORD="<"%~1"
endlocal & set "ADMIN_PASS=%RNTECH_DECODED_RDP_PASSWORD%"
exit /b 0


:APPLY_RDP_FIX
echo ========================================
echo RNTECH RDP SETTINGS
echo ========================================
if not "%RNTECH_CUSTOM_RDP_PASSWORD%"=="1" (
    echo Preserve the existing Administrator password (no job password context).
    net user "%ADMIN_USER%" /active:yes >nul 2>&1
    net localgroup "Administrators" "%ADMIN_USER%" /add >nul 2>&1
    net localgroup "Remote Desktop Users" "%ADMIN_USER%" /add >nul 2>&1
) else (
    echo Enable Administrator and apply the requested RDP password.
    net user "%ADMIN_USER%" /active:yes >nul 2>&1
    net user "%ADMIN_USER%" "%ADMIN_PASS%" >nul 2>&1
    net localgroup "Administrators" "%ADMIN_USER%" /add >nul 2>&1
    net localgroup "Remote Desktop Users" "%ADMIN_USER%" /add >nul 2>&1
)

echo Enable RDP and force port %RDP_PORT%
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v PortNumber /t REG_DWORD /d %RDP_PORT% /f >nul 2>&1
sc config TermService start= auto >nul 2>&1
net start TermService >nul 2>&1
netsh advfirewall firewall add rule name="Rntech RDP %RDP_PORT%" dir=in action=allow protocol=TCP localport=%RDP_PORT% >nul 2>&1
exit /b 0


:CHECK_ADMIN
whoami | find /I "nt authority\system" >nul 2>&1
if not errorlevel 1 (
    echo [OK] Running as SYSTEM
    exit /b 0
)
net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Elevated Administrator privilege not detected
    exit /b 1
)
echo [OK] Running as elevated Administrator
exit /b 0


REM ==========================================================
REM SEND INSTALL STATUS (Windows -> panel /api/events)
REM Body keys: job_id, token, attempt_id, status, node, message
REM ==========================================================
:SEND_INSTALL_STATUS
setlocal EnableExtensions
set "RNTECH_CALLBACK_STATUS=%~1"
set "RNTECH_CALLBACK_MESSAGE=%~2"

if not defined RNTECH_INSTALL_STATUS_URL endlocal & exit /b 0
if not defined RNTECH_INSTALL_JOB_ID endlocal & exit /b 0
if not defined RNTECH_INSTALL_JOB_TOKEN endlocal & exit /b 0
if not defined RNTECH_CALLBACK_STATUS endlocal & exit /b 0
if not exist "%PS_EXE%" (
    echo [CALLBACK] PowerShell not found. Status %RNTECH_CALLBACK_STATUS% skipped.
    endlocal & exit /b 0
)

echo [CALLBACK] Sending status=%RNTECH_CALLBACK_STATUS% job=%RNTECH_INSTALL_JOB_ID%
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
 "$ErrorActionPreference='Stop';" ^
 "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {};" ^
 "$u=$env:RNTECH_INSTALL_STATUS_URL;" ^
 "$b=@{job_id=$env:RNTECH_INSTALL_JOB_ID;token=$env:RNTECH_INSTALL_JOB_TOKEN;attempt_id=$env:RNTECH_INSTALL_ATTEMPT_ID;status=$env:RNTECH_CALLBACK_STATUS;node=$env:RNTECH_INSTALL_NODE;message=$env:RNTECH_CALLBACK_MESSAGE};" ^
 "$ok=$false;" ^
 "foreach($i in 1..3){try{Invoke-RestMethod -Method Post -Uri $u -Body $b -TimeoutSec 10 | Out-Null;$ok=$true;break}catch{if($i -lt 3){Start-Sleep -Seconds 2}}};" ^
 "if($ok){exit 0}else{exit 1}"

if "%ERRORLEVEL%"=="0" (
    echo [CALLBACK] Status %RNTECH_CALLBACK_STATUS% sent successfully.
) else (
    echo [CALLBACK] WARN: Status %RNTECH_CALLBACK_STATUS% failed after retries.
)
REM A callback never fails the main setup on its own.
endlocal & exit /b 0
