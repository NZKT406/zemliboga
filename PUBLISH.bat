@echo off
rem Publishes the current game version to GitHub (only changed files). Friends get it via LAUNCHER.bat.
rem System tools are called by full path, so a broken PATH variable does not matter.
cd /d "%~dp0"
set "SYS=%SystemRoot%\System32"
"%SYS%\chcp.com" 65001 >nul
"%SYS%\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\publish.ps1"
pause
