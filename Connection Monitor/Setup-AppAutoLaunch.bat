@echo off
set "APP_SHORTCUT=C:\Users\PG1\Desktop\Platform Golf.lnk"

echo Setting up automatic launch of the Platform Golf app at logon...
echo (This must be run as Administrator -- creating ANY scheduled task requires
echo  elevation, even one that will run as your own account. Right-click this
echo  file and choose "Run as administrator" if it fails below.)
echo.

if not exist "%APP_SHORTCUT%" (
    echo WARNING: could not find "%APP_SHORTCUT%" -- double check the shortcut
    echo path/name on the Desktop matches exactly before continuing.
    echo.
)

REM /RU PG1 + /IT ensures this runs in PG1's own visible desktop session at
REM logon (not as SYSTEM, which would run invisibly), and /IT ("run only if
REM logged on") means no password needs to be stored for it to work.
schtasks /Create /TN "Launch Platform Golf App" ^
  /TR "explorer.exe \"%APP_SHORTCUT%\"" ^
  /SC ONLOGON /RU "PG1" /IT /F

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo FAILED to create the task. See the error above.
    pause
    exit /b 1
)

echo.
echo Done. The Platform Golf app will now open automatically every time PG1
echo logs in -- including after reboots the Connection Monitor triggers on
echo its own, since this PC auto-logs in. Future idle/fault occurrences
echo caught by the monitor will now happen with the app open, matching real
echo usage.
echo.
echo To undo this later: schtasks /Delete /TN "Launch Platform Golf App" /F
echo.
pause
