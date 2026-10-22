@echo off
title Monitor SFTP - feche esta janela para parar
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File Monitor-SFTP.ps1
pause
