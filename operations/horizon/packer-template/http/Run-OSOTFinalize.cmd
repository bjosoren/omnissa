@echo off
mkdir C:\Temp\OSOT-logs 2>nul

REM Copy OSOT to short name to avoid WinRM line-wrap issue with long filename
copy /Y "C:\Temp\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe" "C:\Temp\osot.exe" >nul

set OSOT=C:\Temp\osot.exe
set LOG=C:\Temp\OSOT-logs\OSOT-Finalize.log
set REPORT=C:\Temp\OSOT-logs\OSOT-Finalize-report.txt

echo [%DATE% %TIME%] Starting OSOT Finalize >> "%LOG%"
echo [%DATE% %TIME%] OSOT executable: %OSOT% >> "%LOG%"
echo [%DATE% %TIME%] Steps: 0 1 2 3 4 5 6 7 9 10 >> "%LOG%"

REM Steps: 0=.NET, 1=WinSxS, 2=CompactOS, 3=Temp, 4=EventLogs
REM        5=Superfetch, 6=DefaultProfile, 7=sdelete, 9=KMS, 10=DNS
REM Excluded: 8=LGPO (no tool), 11=Release IP (breaks network)

"%OSOT%" -Finalize 0 1 2 3 4 5 6 7 9 10 -v -r "%REPORT%" >> "%LOG%" 2>&1

echo [%DATE% %TIME%] OSOT Finalize exit code: %ERRORLEVEL% >> "%LOG%"
exit %ERRORLEVEL%
