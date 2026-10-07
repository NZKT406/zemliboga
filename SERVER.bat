@echo off
rem Dedicated game server without a player (optional): accounts and rooms for up to 8 players.
rem Usually you don't need it - one of the players just presses "Create game" in the Network menu.
rem Friends connect to the address of this PC (Radmin VPN: 26.x.x.x), port 24600.
cd /d "%~dp0"
set "SYS=%SystemRoot%\System32"
if not exist "engine\Godot_v4.6-stable_win64.exe" (
  echo First launch: unpacking the Godot engine, please wait...
  copy /b "engine\godot.zip.001"+"engine\godot.zip.002"+"engine\godot.zip.003"+"engine\godot.zip.004" "engine\godot.zip" >nul
  "%SYS%\tar.exe" -xf "engine\godot.zip" -C "engine"
  del "engine\godot.zip"
)
echo Addresses of this computer (Radmin VPN address starts with 26.):
for /f "tokens=2 delims=:" %%a in ('"%SYS%\ipconfig.exe" ^| "%SYS%\findstr.exe" /c:"IPv4"') do echo    %%a
echo Game port 24600. Close this window to stop the server.
"%SYS%\chcp.com" 65001 >nul
"engine\Godot_v4.6-stable_win64_console.exe" --headless --main-pack "%~dp0game.pck" -- --server %*
pause
