@echo off
mkdir C:\Temp\OSOT-logs 2>nul

REM Copy OSOT to short name to avoid path issues
copy /Y "C:\Temp\OmnissaHorizonOSOptimizationTool-x86_64-1.2.2603.23605577104.exe" "C:\Temp\osot.exe" >nul

set OSOT=C:\Temp\osot.exe
set XML=C:\Temp\w11sysprep.xml
set LOG=C:\Temp\OSOT-logs\OSOT-Generalize.log
set REPORT=C:\Temp\OSOT-logs\OSOT-Generalize-report.txt

echo [%DATE% %TIME%] Starting OSOT Generalize >> "%LOG%"
echo [%DATE% %TIME%] OSOT executable: %OSOT% >> "%LOG%"
echo [%DATE% %TIME%] Sysprep XML    : %XML% >> "%LOG%"
echo [%DATE% %TIME%] NOTE: VM will shut down after generalize >> "%LOG%"

REM Per official docs syntax: -g [answerfile] [-reboot | -shutdown]
REM Using -shutdown so Packer can detect the VM shutdown and reconnect after reboot
"%OSOT%" -g "%XML%" -shutdown -v -r "%REPORT%" >> "%LOG%" 2>&1

echo [%DATE% %TIME%] OSOT Generalize exit code: %ERRORLEVEL% >> "%LOG%"
exit %ERRORLEVEL%
