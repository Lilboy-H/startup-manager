@echo off
chcp 65001 >nul
title 清理测试残留
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0清理测试残留.ps1"
