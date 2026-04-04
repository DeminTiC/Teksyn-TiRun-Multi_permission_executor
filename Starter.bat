@echo off
title Teksyn - 提权执行器 - 环境准备
:: 检查管理员权限
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 请求管理员权限...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: 切换到脚本所在目录
cd /d "%~dp0"

:: 直接以 Bypass 策略启动 GUI（无需修改系统策略）
echo 正在启动 提权执行器...
powershell -ExecutionPolicy Bypass -File "TiUser.ps1"

:: 脚本结束
pause