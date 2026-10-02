@echo off
rem Downloads pdf-editor.html from GitHub into C:\BK\Vibecoding
setlocal
set "DEST=C:\BK\Vibecoding"
set "URL=https://raw.githubusercontent.com/BKPark-cpu/First/claude/github-pdf-editor-search-zqsy8h/pdf-editor.html"

if not exist "%DEST%" mkdir "%DEST%"
echo Downloading pdf-editor.html to %DEST% ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%DEST%\pdf-editor.html'"
if errorlevel 1 (
  echo Download failed. Check your internet connection and try again.
  pause
  exit /b 1
)
echo Done: %DEST%\pdf-editor.html
start "" "%DEST%"
pause
