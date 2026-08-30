@echo off
powershell -NoProfile -Command "Invoke-WebRequest -Method Post -Uri 'http://127.0.0.1:8889/press' -UseBasicParsing" 
timeout /t 0.12 >nul
powershell -NoProfile -Command "Invoke-WebRequest -Method Post -Uri 'http://127.0.0.1:8889/release' -UseBasicParsing" 
