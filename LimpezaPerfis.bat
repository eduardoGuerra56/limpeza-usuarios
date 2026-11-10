@echo off
REM Duplo clique para abrir a Limpeza de Perfis (pede permissao de administrador)
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LimpezaPerfis.ps1"
