@echo off
powershell -NoProfile -Command "Invoke-WebRequest -Method Post -Uri 'http://127.0.0.1:8889/release' -UseBasicParsing" 
