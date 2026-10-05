@echo off
rem ZEMLIBOGA launcher: checks GitHub for updates, downloads changed files, then starts the game.
rem System tools are called by full path, so a broken PATH variable does not matter.
cd /d "%~dp0"
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher\launcher.ps1"
