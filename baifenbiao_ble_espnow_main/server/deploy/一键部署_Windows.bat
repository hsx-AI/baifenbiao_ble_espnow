@echo off
setlocal
cd /d "%~dp0"

echo ========================================
echo  百分表网关 - Windows 离线一键部署
echo ========================================
echo.

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 需要管理员权限，正在请求提升...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_windows.ps1"
if errorlevel 1 (
    echo.
    echo 部署失败，请查看上方错误信息。
    pause
    exit /b 1
)

echo.
echo 部署完成。
pause
