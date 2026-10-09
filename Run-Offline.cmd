@echo off
setlocal
cd /d "%~dp0"
call "%~dp0Run-Istrolid.cmd" -Offline %*
