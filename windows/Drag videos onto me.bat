@echo off
rem Fallback: drag one or more video files onto this .bat to compress them.
rem No PowerShell / .NET / GUI needed. Works on Windows 7 x64 and later.
setlocal enabledelayedexpansion
cd /d "%~dp0"
set "FF=%~dp0bin\ffmpeg.exe"
set "FP=%~dp0bin\ffprobe.exe"
set "CRF=16"

if not exist "%FF%" (
  echo [ERROR] bin\ffmpeg.exe not found. Extract the whole folder first.
  pause
  exit /b 1
)
if "%~1"=="" (
  echo Drag one or more video files onto this .bat file.
  echo Output: same folder as source, named *_compressed.mp4
  echo Quality: HEVC CRF %CRF%, constant frame rate, original resolution/audio kept.
  pause
  exit /b 0
)

:LOOP
if "%~1"=="" goto DONE
set "SRC=%~1"
if not exist "%SRC%" (
  echo [SKIP] File not found: %SRC%
  shift
  goto LOOP
)

set "RATE="
if exist "%FP%" (
  for /f "usebackq delims=" %%R in (`"%FP%" -v error -select_streams v:0 -show_entries stream^=r_frame_rate -of default^=nwpr^=n1:nk^=1 "%SRC%" 2^>nul`) do set "RATE=%%R"
)
set "FPSARGS=-fps_mode cfr"
if defined RATE set "FPSARGS=-fps_mode cfr -r !RATE! -video_track_timescale 30000"

set "OUT=%~dpn1_compressed.mp4"
set /a N=2
:UNIQUE
if exist "%OUT%" (
  set "OUT=%~dpn1_compressed-!N!.mp4"
  set /a N+=1
  goto UNIQUE
)

echo.
echo [INPUT ] %SRC%
echo [OUTPUT] %OUT%
if defined RATE (echo [FPS   ] !RATE! CFR locked) else (echo [FPS   ] source CFR locked)

"%FF%" -hide_banner -nostdin -loglevel warning -stats -i "%SRC%" -map 0:v:0 -c:v libx265 -preset medium -crf %CRF% -tag:v hvc1 -pix_fmt yuv420p !FPSARGS! -map 0:a? -c:a copy -map_metadata 0 -movflags +faststart -y "%OUT%"
if errorlevel 1 (
  echo [RETRY] audio stream could not be copied, re-encoding to AAC...
  "%FF%" -hide_banner -nostdin -loglevel warning -stats -i "%SRC%" -map 0:v:0 -c:v libx265 -preset medium -crf %CRF% -tag:v hvc1 -pix_fmt yuv420p !FPSARGS! -map 0:a? -c:a aac -b:a 192k -map_metadata 0 -movflags +faststart -y "%OUT%"
)
if exist "%OUT%" (
  for %%A in ("%OUT%") do echo [DONE  ] %%~zA bytes  ^(constant frame rate^)
) else (
  echo [FAILED] %SRC%
)
shift
goto LOOP

:DONE
echo.
echo All jobs finished. Original files were NOT modified.
pause
exit /b 0
