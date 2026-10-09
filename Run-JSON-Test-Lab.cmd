@echo off
setlocal
cd /d "%~dp0security-lab"
where node.exe >nul 2>&1
if errorlevel 1 (
  echo Node.js 20 or newer is required. Install the LTS release from https://nodejs.org/
  pause
  exit /b 1
)
if not exist "node_modules\ws" (
  echo Installing the isolated security-lab dependency...
  call npm install --ignore-scripts --no-audit --no-fund
  if errorlevel 1 (echo Dependency installation failed & pause & exit /b 1)
)
node src\cli.mjs %*
if errorlevel 1 (echo Security lab failed & pause & exit /b 1)
