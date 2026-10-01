@echo off
rem Performance report - unit self test (24 cases)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-PerformanceReport.ps1" -SelfTest
pause
