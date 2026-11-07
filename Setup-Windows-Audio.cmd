@echo off
setlocal
rem One-click Windows setup for LAN Audio Bridge. Usage: Setup-Windows-Audio.cmd [Setup|Status|Start|Stop|Restore] [options]
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if "%~1"=="" ("%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-audio.ps1") else ("%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-audio.ps1" -Action %*)
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo Setup did not complete. See the message above.
pause
exit /b %RESULT%
