@echo off
cd /d "%~dp0"
python bo7_extract.py %*
if errorlevel 1 pause
