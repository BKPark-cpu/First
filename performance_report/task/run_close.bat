@echo off
rem Performance report - CLOSE the month (only when validation errors = 0). Usage: run_close.bat yyyy-MM
if "%~1"=="" (
  echo Usage: run_close.bat yyyy-MM   ^(example: run_close.bat 2026-02^)
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-PerformanceReport.ps1" -InputDir "%~dp0input" -OutDir "%~dp0output" -Month %~1 -Close
pause
