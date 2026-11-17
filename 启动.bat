@echo off
chcp 65001 >nul
title 自启动管家
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0main.ps1"
