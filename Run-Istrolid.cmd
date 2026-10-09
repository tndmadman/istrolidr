@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Build-And-Run.ps1" %*
if errorlevel 1 (
    echo.
    echo Build or launch failed. Review the message above.
    pause
    exit /b 1
)
exit /b 0
