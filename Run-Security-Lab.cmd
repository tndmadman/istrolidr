@echo off
setlocal
cd /d "%~dp0"
where node.exe >nul 2>&1
if errorlevel 1 (echo Node.js 20+ required. Install Node.js LTS. & pause & exit /b 1)
echo Building locally installed Istrolid client to read its original protocol table...
call "%~dp0Build-Only.cmd"
if errorlevel 1 (echo Could not extract installed game assets. & pause & exit /b 1)
cd /d "%~dp0security-lab"
if not exist "node_modules\ws" (
  call npm install --ignore-scripts --no-audit --no-fund
  if errorlevel 1 (echo Dependency install failed. & pause & exit /b 1)
)
node src\istrolid-native-cli.mjs --bundle "%~dp0.build\Istrolid\resources\app\js\istrolid.cat.js" %*
if errorlevel 1 (echo Native server failed. & pause & exit /b 1)
