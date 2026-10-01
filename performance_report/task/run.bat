@echo off
rem Performance report - validate + draft report (no close). Usage: run.bat [yyyy-MM]  (default: previous month)
set M=%~1
if "%M%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-PerformanceReport.ps1" -InputDir "%~dp0input" -OutDir "%~dp0output"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-PerformanceReport.ps1" -InputDir "%~dp0input" -OutDir "%~dp0output" -Month %M%
)
pause
