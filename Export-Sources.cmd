@echo off
setlocal
cd /d "%~dp0"
call "%~dp0Build-Only.cmd" %*
if errorlevel 1 (echo Build failed & pause & exit /b 1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Source-Modules.ps1" -Bundle "%~dp0.build\IstrolidR\resources\app\js\istrolid.cat.js" -ExportDirectory "%~dp0.build\sources"
if errorlevel 1 (echo Source export failed & pause & exit /b 1)
echo.
echo Your editable local source is in: .build\sources\
echo Copy a module into modules\ with the same relative path to override it.
pause
