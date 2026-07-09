@echo off
mkdir C:\Temp\OSOT-logs 2>nul

REM Copy OSOT to short name to avoid WinRM line-wrap issue with long filename
copy /Y "C:\Temp\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe" "C:\Temp\osot.exe" >nul

set OSOT=C:\Temp\osot.exe
set JSON=C:\Temp\Windows 10, 11 and Server 2019, 2022 2026-07-08-085321.json
set LOG=C:\Temp\OSOT-logs\OSOT-Optimize.log
set REPORT=C:\Temp\OSOT-logs\OSOT-Optimize-report.txt

echo [%DATE% %TIME%] Starting OSOT Optimize >> "%LOG%"
echo [%DATE% %TIME%] OSOT executable: %OSOT% >> "%LOG%"
echo [%DATE% %TIME%] Settings JSON  : %JSON% >> "%LOG%"

"%OSOT%" -o -ApplyOptimization "%JSON%" -v -r "%REPORT%" >> "%LOG%" 2>&1

echo [%DATE% %TIME%] OSOT Optimize exit code: %ERRORLEVEL% >> "%LOG%"
exit %ERRORLEVEL%
