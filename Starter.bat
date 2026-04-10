@echo off
title Teksyn - 权限执行器 - 环境准备
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 请求管理员权限...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

:: 以Bypass策略启动GUI
echo 正在启动 权限执行器...
powershell -ExecutionPolicy Bypass -File "TiUser.ps1"

pause
:: 说句实在话这个启动脚本真没啥好改的