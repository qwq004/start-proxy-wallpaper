@echo off
rem One-time installer: creates the desktop shortcut and runs the script once.
rem After this, just double-click the desktop shortcut.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-proxy-wallpaper.ps1"
echo.
echo [OK] Desktop shortcut created - Startup Proxy + Wallpaper.
echo      From now on, double-click that shortcut.
pause
