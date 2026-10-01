@echo off
rem Performance report - sample run (month 2026-02, fixed timestamp, no close)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-PerformanceReport.ps1" -InputDir "%~dp0samples\input" -OutDir "%~dp0samples\output" -Month 2026-02 -Now "2026-03-05 09:00" -Operator sample
pause
