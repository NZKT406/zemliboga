@echo off
cd /d "%~dp0"
if not exist "engine\Godot_v4.6-stable_win64.exe" (
  echo First launch: unpacking the Godot engine, please wait...
  copy /b "engine\godot.zip.001"+"engine\godot.zip.002"+"engine\godot.zip.003"+"engine\godot.zip.004" "engine\godot.zip" >nul
  "%SystemRoot%\System32\tar.exe" -xf "engine\godot.zip" -C "engine"
  del "engine\godot.zip"
)
if not exist "engine\Godot_v4.6-stable_win64.exe" (
  echo ERROR: could not unpack Godot. Tell Claude what you see above.
  pause
  exit /b 1
)
if not exist "logs" mkdir "logs"
if exist "logs\game.log" copy /y "logs\game.log" "logs\game_prev.log" >nul
start "" "engine\Godot_v4.6-stable_win64.exe" --path "game" --log-file "%~dp0logs\game.log" %*
