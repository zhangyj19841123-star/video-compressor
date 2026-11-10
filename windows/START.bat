@echo off
rem Launch the native Windows GUI (WinForms via PowerShell, built into Win7+)
cd /d "%~dp0"
if not exist "bin\ffmpeg.exe" (
  echo [ERROR] bin\ffmpeg.exe not found.
  echo Please extract the WHOLE folder before running.
  pause
  exit /b 1
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Windows PowerShell not found.
  echo Please use "Drag videos onto me.bat" instead.
  pause
  exit /b 1
)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app.ps1"
exit /b 0
