@echo off
setlocal
rem Low-latency Windows sender (WASAPI loopback -> VBAN). Actions: Setup (default), Status, Start, Stop, Restore.
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if "%~1"=="" ("%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-sender.ps1") else ("%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-sender.ps1" -Action %*)
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo The sender setup did not complete. See the message above.
pause
exit /b %RESULT%
