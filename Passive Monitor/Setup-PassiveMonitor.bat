@echo off
set "MONITOR_DIR=C:\Users\PG1\Documents\Passive Monitor"

echo Setting up the Passive Connection Monitor scheduled task...
echo (This must be run as Administrator -- right-click this file and choose
echo  "Run as administrator" if it fails below.)
echo.
echo IMPORTANT: this is meant to run INSTEAD OF the original Connection
echo Monitor, not alongside it -- the original still opens the COM port
echo every 30 seconds, which would defeat the point of this test. If the
echo original is running, stop it first with Stop-Monitor.bat.
echo.

if not exist "%MONITOR_DIR%" mkdir "%MONITOR_DIR%"

REM Creates (or replaces) a task that runs passive-monitor.ps1 hidden in the
REM background, starts at boot, and runs as SYSTEM (works with nobody logged
REM in, has rights to restart the computer, never prompts for a password).
schtasks /Create /TN "Passive Connection Monitor" ^
  /TR "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%MONITOR_DIR%\passive-monitor.ps1\"" ^
  /SC ONSTART /RU SYSTEM /RL HIGHEST /F

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo FAILED. Make sure you ran this as Administrator, and that
    echo "%MONITOR_DIR%\passive-monitor.ps1" exists.
    pause
    exit /b 1
)

echo.
echo Creating a "View Log" shortcut inside the Passive Monitor folder...
powershell -NoProfile -Command ^
  "$s = (New-Object -ComObject WScript.Shell).CreateShortcut('%MONITOR_DIR%\View Log.lnk');" ^
  "$s.TargetPath = 'notepad.exe';" ^
  "$s.Arguments = '\"%MONITOR_DIR%\passive-monitor.log\"';" ^
  "$s.WorkingDirectory = '%MONITOR_DIR%';" ^
  "$s.Description = 'Open the Passive Connection Monitor log';" ^
  "$s.Save()"

echo.
echo Task created. Starting it now...
schtasks /Run /TN "Passive Connection Monitor"

echo.
echo Done. Everything lives in:
echo   %MONITOR_DIR%
echo.
echo This monitor only reads C:\ProgramData\Platform Golf\logs -- it never
echo opens the COM port, so it will not keep the device awake by itself.
echo.
echo Use Stop-PassiveMonitor.bat / Start-PassiveMonitor.bat going forward.
echo.
pause
