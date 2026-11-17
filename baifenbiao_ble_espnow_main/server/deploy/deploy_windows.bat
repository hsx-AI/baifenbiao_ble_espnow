@echo off
setlocal
cd /d "%~dp0"

echo ========================================
echo  Percent Meter - Windows Offline Deploy
echo ========================================
echo.
echo This will:
echo   1. Install files to C:\PercentMeter
echo   2. Create Windows service "PercentMeter"
echo   3. Set auto-start on boot
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1"
if errorlevel 1 (
    echo.
    echo Deploy FAILED. See errors above.
    pause
    exit /b 1
)

echo.
echo Deploy OK. Service PercentMeter is set to auto-start.
echo Open: http://127.0.0.1:8000
pause
