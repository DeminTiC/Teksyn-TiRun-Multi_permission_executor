@echo off
title Teksyn - 权限执行器

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 请求管理员权限...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

echo.
echo   TiRun 多权限执行器
echo ========================================
echo   1. 图形界面模式 (GUI)
echo   2. 交互式控制台模式 (CLI)
echo   3. 退出
set /p choice="请输入数字 (1-3): "

if "%choice%"=="1" goto GUI
if "%choice%"=="2" goto CLI
if "%choice%"=="3" exit
echo 无效输入，默认启动图形界面
goto GUI

:GUI
echo 正在启动图形界面...
powershell -ExecutionPolicy Bypass -File "TiUser.ps1"
pause
exit

:CLI
echo 正在启动交互式控制台...
powershell -ExecutionPolicy Bypass -File "TiUser.ps1" -Interactive
pause
exit