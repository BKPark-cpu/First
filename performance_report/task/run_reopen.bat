@echo off
rem Performance report - REOPEN the latest closed month. Usage: run_reopen.bat yyyy-MM "reason"
if "%~2"=="" (
  echo Usage: run_reopen.bat yyyy-MM "reason"
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-PerformanceReport.ps1" -InputDir "%~dp0input" -OutDir "%~dp0output" -Month %~1 -Reopen -Reason "%~2"
pause
