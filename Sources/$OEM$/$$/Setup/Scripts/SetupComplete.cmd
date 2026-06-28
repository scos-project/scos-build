@echo off
setlocal

REM ============================================================
REM SCOS SetupComplete bootstrapper
REM SCOS Standard / Developer v0.3
REM ============================================================

set "LOG=C:\SetupComplete.log"

REM === SCOS edition handoff from SCOS Builder ===
REM SCOS Builder writes SCOS_Edition.txt into the same Scripts folder as SetupComplete.cmd.
REM Valid values:
REM   Standard  = lockdown enabled
REM   Developer = lockdown disabled

set "SCRIPTROOT=%~dp0"
set "SCOS_EDITION_FILE=%SCRIPTROOT%SCOS_Edition.txt"

REM Default to Standard for safety if the edition file is missing, empty, or invalid.
set "SCOS_EDITION_RAW=Standard"
set "SCOS_EDITION=Standard"
set "SCOS_LOCKDOWN=1"

if exist "%SCOS_EDITION_FILE%" (
  for /f "usebackq tokens=* delims=" %%A in ("%SCOS_EDITION_FILE%") do (
    set "SCOS_EDITION_RAW=%%A"
    goto :GotEditionFromFile
  )
)

:GotEditionFromFile

if /i "%SCOS_EDITION_RAW%"=="Developer" (
  set "SCOS_EDITION=Developer"
  set "SCOS_LOCKDOWN=0"
) else (
  set "SCOS_EDITION=Standard"
  set "SCOS_LOCKDOWN=1"
)

REM --- RUN-ONCE GUARD ---
if exist C:\SetupComplete.ran (
  echo [%date% %time%] Marker exists, exiting.>>"%LOG%"
  exit /b 0
)

echo. > C:\SetupComplete.ran
echo [%date% %time%] SetupComplete starting...>>"%LOG%"
echo [%date% %time%] SCOS edition: %SCOS_EDITION%.>>"%LOG%"
echo [%date% %time%] SCOS lockdown: %SCOS_LOCKDOWN%.>>"%LOG%"

REM --- Paths ---
set "SCRIPTROOT_CLEAN=%SCRIPTROOT%"
if "%SCRIPTROOT_CLEAN:~-1%"=="\" set "SCRIPTROOT_CLEAN=%SCRIPTROOT_CLEAN:~0,-1%"
set "SCOS_SETUP_DIR=C:\SCOS\Setup"
set "SCOS_LOG_DIR=C:\SCOS\Logs"

set "SCOS_UI_SOURCE=%SCRIPTROOT%SCOSSetupProgress.ps1"
set "SCOS_UI_INSTALLED=%SCOS_SETUP_DIR%\SCOSSetupProgress.ps1"

set "SCOS_LAUNCHER_PS_SOURCE=%SCRIPTROOT%RunSCOSSetup.ps1"
set "SCOS_LAUNCHER_PS=%SCOS_SETUP_DIR%\RunSCOSSetup.ps1"
set "SCOS_LAUNCHER_CMD=%SCOS_SETUP_DIR%\RunSCOSSetup.cmd"

REM --- Validate required SCOS setup files in C:\Windows\Setup\Scripts ---
if not exist "%SCOS_UI_SOURCE%" (
  echo [%date% %time%] ERROR: SCOSSetupProgress.ps1 not found at "%SCOS_UI_SOURCE%".>>"%LOG%"
  exit /b 1
)

if not exist "%SCOS_LAUNCHER_PS_SOURCE%" (
  echo [%date% %time%] ERROR: RunSCOSSetup.ps1 not found at "%SCOS_LAUNCHER_PS_SOURCE%".>>"%LOG%"
  exit /b 1
)

REM --- Prepare SCOS folders ---
mkdir "C:\SCOS" 2>nul
mkdir "%SCOS_SETUP_DIR%" 2>nul
mkdir "%SCOS_LOG_DIR%" 2>nul
mkdir "C:\SCOS\Scripts" 2>nul
mkdir "C:\SteamShell" 2>nul
mkdir "C:\SteamConsole" 2>nul

REM --- Allow the SCOS user to write launcher/setup logs ---
icacls "%SCOS_LOG_DIR%" /grant *S-1-5-32-545:(OI)(CI)(M) /T /C >>"%LOG%" 2>&1
icacls "%SCOS_SETUP_DIR%" /grant *S-1-5-32-545:(OI)(CI)(RX) /T /C >>"%LOG%" 2>&1

REM --- Copy the setup UI and PowerShell launcher onto the installed system ---
echo [%date% %time%] Copying SCOS setup UI...>>"%LOG%"
copy "%SCOS_UI_SOURCE%" "%SCOS_UI_INSTALLED%" /y >>"%LOG%" 2>&1

if not exist "%SCOS_UI_INSTALLED%" (
  echo [%date% %time%] ERROR: Failed to copy SCOSSetupProgress.ps1 to "%SCOS_UI_INSTALLED%".>>"%LOG%"
  exit /b 1
)

echo [%date% %time%] Copying SCOS PowerShell launcher...>>"%LOG%"
copy "%SCOS_LAUNCHER_PS_SOURCE%" "%SCOS_LAUNCHER_PS%" /y >>"%LOG%" 2>&1

if not exist "%SCOS_LAUNCHER_PS%" (
  echo [%date% %time%] ERROR: Failed to copy RunSCOSSetup.ps1 to "%SCOS_LAUNCHER_PS%".>>"%LOG%"
  exit /b 1
)

REM --- Keep small setup state files ---
echo %SCOS_EDITION%>"%SCOS_SETUP_DIR%\SCOS_EDITION.txt"
echo %SCOS_LOCKDOWN%>"%SCOS_SETUP_DIR%\SCOS_LOCKDOWN.txt"
echo %SCRIPTROOT%>"%SCOS_SETUP_DIR%\SCOS_ORIGINAL_SCRIPTROOT.txt"
echo. >"%SCOS_SETUP_DIR%\SCOS_INSTALL_PENDING"

REM ============================================================
REM Create CMD launcher.
REM Winlogon shell runs this file.
REM This file then launches RunSCOSSetup.ps1.
REM ============================================================

echo [%date% %time%] Creating SCOS first-login CMD launcher...>>"%LOG%"

(
echo @echo off
echo setlocal
echo set "LOG=C:\SCOS\Logs\SCOSLauncher.cmd.log"
echo echo [%%date%% %%time%%] SCOS temporary shell CMD launcher started.^>^>"%%LOG%%"
echo echo [%%date%% %%time%%] Checking SCOS PowerShell launcher...^>^>"%%LOG%%"
echo.
echo if not exist "C:\SCOS\Setup\RunSCOSSetup.ps1" ^(
echo   echo [%%date%% %%time%%] ERROR: RunSCOSSetup.ps1 is missing.^>^>"%%LOG%%"
echo   echo.
echo   echo SCOS setup launcher is missing.
echo   echo Check C:\SCOS\Logs\SCOSLauncher.cmd.log
echo   pause
echo   exit /b 1
echo ^)
echo.
echo echo [%%date%% %%time%%] Starting PowerShell launcher...^>^>"%%LOG%%"
echo "%%SystemRoot%%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "C:\SCOS\Setup\RunSCOSSetup.ps1" -ScriptsRoot "%SCRIPTROOT_CLEAN%" -Edition "%SCOS_EDITION%" -Lockdown %SCOS_LOCKDOWN%
echo set "SCOS_EXIT=%%ERRORLEVEL%%"
echo echo [%%date%% %%time%%] SCOS temporary shell launcher exited with code %%SCOS_EXIT%%.^>^>"%%LOG%%"
echo.
echo if not "%%SCOS_EXIT%%"=="0" ^(
echo   echo.
echo   echo SCOS setup failed.
echo   echo Check C:\SCOS\Logs\SCOSLauncher.cmd.log and C:\SCOS\Logs\SCOSSetup.log
echo   pause
echo ^)
echo.
echo exit /b %%SCOS_EXIT%%
) > "%SCOS_LAUNCHER_CMD%"

if not exist "%SCOS_LAUNCHER_CMD%" (
  echo [%date% %time%] ERROR: CMD launcher was not created.>>"%LOG%"
  exit /b 1
)

REM ============================================================
REM Set temporary shell early.
REM From this point, Windows should not boot to Explorer anymore.
REM The UI replaces this with Steam Big Picture shell after success.
REM ============================================================

echo [%date% %time%] Setting temporary SCOS setup shell early...>>"%LOG%"

reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "cmd.exe /c C:\SCOS\Setup\RunSCOSSetup.cmd" /f >>"%LOG%" 2>&1

if not "%ERRORLEVEL%"=="0" (
  echo [%date% %time%] ERROR: Failed to set temporary SCOS setup shell.>>"%LOG%"
  exit /b 1
)

REM ============================================================
REM Temporarily reduce UAC prompts during SCOS first-login setup.
REM The UI restores these values at the end.
REM ============================================================

echo [%date% %time%] Saving current UAC prompt settings...>>"%LOG%"

for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v ConsentPromptBehaviorAdmin 2^>nul ^| find "ConsentPromptBehaviorAdmin"') do (
  echo %%A>"%SCOS_SETUP_DIR%\UAC_ConsentPromptBehaviorAdmin.old"
)

for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v PromptOnSecureDesktop 2^>nul ^| find "PromptOnSecureDesktop"') do (
  echo %%A>"%SCOS_SETUP_DIR%\UAC_PromptOnSecureDesktop.old"
)

echo [%date% %time%] Temporarily allowing silent admin elevation for SCOS setup...>>"%LOG%"

reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f >>"%LOG%" 2>&1

REM ============================================================
REM Final validation
REM ============================================================

if not exist "%SCOS_LAUNCHER_CMD%" (
  echo [%date% %time%] ERROR: Final validation failed. CMD launcher missing.>>"%LOG%"
  exit /b 1
)

if not exist "%SCOS_LAUNCHER_PS%" (
  echo [%date% %time%] ERROR: Final validation failed. PowerShell launcher missing.>>"%LOG%"
  exit /b 1
)

if not exist "%SCOS_UI_INSTALLED%" (
  echo [%date% %time%] ERROR: Final validation failed. Setup UI missing.>>"%LOG%"
  exit /b 1
)

echo [%date% %time%] SCOS launcher files copied/created successfully.>>"%LOG%"
echo [%date% %time%] SetupComplete finished. SCOS setup UI will run on first login.>>"%LOG%"

exit /b 0