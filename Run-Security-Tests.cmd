@echo off
setlocal
cd /d "%~dp0security-lab"
where node.exe >nul 2>&1
if errorlevel 1 (echo Node.js 20+ required & pause & exit /b 1)
if not exist "node_modules\ws" (
  call npm install --ignore-scripts --no-audit --no-fund
  if errorlevel 1 (echo npm install failed & pause & exit /b 1)
)
call npm test
if errorlevel 1 (echo Tests failed & pause & exit /b 1)
echo Security lab tests passed.
pause
