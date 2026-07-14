@echo off
set "MONITOR_DIR=C:\Users\PG1\Documents\Connection Monitor"

echo Setting up the Connection Monitor scheduled task...
echo (This must be run as Administrator -- right-click this file and choose
echo  "Run as administrator" if it fails below.)
echo.

if not exist "%MONITOR_DIR%" mkdir "%MONITOR_DIR%"

REM Creates (or replaces, if it already exists) a task that:
REM  - runs connection-monitor.ps1 hidden in the background
REM  - starts automatically every time this PC boots
REM  - runs as SYSTEM, so it works whether or not anyone is logged in,
REM    with the privileges needed to restart the computer, and without
REM    ever prompting for a password
schtasks /Create /TN "Connection Monitor" ^
  /TR "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%MONITOR_DIR%\connection-monitor.ps1\"" ^
  /SC ONSTART /RU SYSTEM /RL HIGHEST /F

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo FAILED. Make sure you ran this as Administrator, and that
    echo "%MONITOR_DIR%\connection-monitor.ps1" exists.
    pause
    exit /b 1
)

echo.
echo Creating a "View Log" shortcut inside the Connection Monitor folder...
powershell -NoProfile -Command ^
  "$s = (New-Object -ComObject WScript.Shell).CreateShortcut('%MONITOR_DIR%\View Log.lnk');" ^
  "$s.TargetPath = 'notepad.exe';" ^
  "$s.Arguments = '\"%MONITOR_DIR%\connection-monitor.log\"';" ^
  "$s.WorkingDirectory = '%MONITOR_DIR%';" ^
  "$s.Description = 'Open the Connection Monitor log';" ^
  "$s.Save()"

echo.
echo Task created. Starting it now...
schtasks /Run /TN "Connection Monitor"

echo.
echo Done. Everything lives in:
echo   %MONITOR_DIR%
echo.
echo That folder now contains the script, this setup file, Start/Stop-Monitor.bat,
echo the log itself once it starts writing, and a "View Log" shortcut for quick access.
echo.
echo Use Stop-Monitor.bat / Start-Monitor.bat going forward -- you should
echo not need to run this Setup-Monitor.bat again unless the task gets
echo deleted.
echo.
pause
