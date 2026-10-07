@echo off
rem Starts the game without checking for updates (the game itself is game.pck).
cd /d "%~dp0"
set "SYS=%SystemRoot%\System32"
if not exist "engine\Godot_v4.6-stable_win64.exe" (
  echo First launch: unpacking the Godot engine, please wait...
  copy /b "engine\godot.zip.001"+"engine\godot.zip.002"+"engine\godot.zip.003"+"engine\godot.zip.004" "engine\godot.zip" >nul
  "%SYS%\tar.exe" -xf "engine\godot.zip" -C "engine"
  del "engine\godot.zip"
)
if not exist "logs" mkdir "logs"
if exist "logs\game.log" copy /y "logs\game.log" "logs\game_prev.log" >nul
start "" "engine\Godot_v4.6-stable_win64.exe" --main-pack "%~dp0game.pck" --log-file "%~dp0logs\game.log" %*
