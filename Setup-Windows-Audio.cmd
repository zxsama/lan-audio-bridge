@echo off
setlocal
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS_EXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows-audio.ps1" %*
set "RESULT=%ERRORLEVEL%"
if "%RESULT%"=="3010" echo Restart Windows when convenient. Configuration will continue after sign-in.
if not "%RESULT%"=="0" if not "%RESULT%"=="3010" echo Setup did not complete. See the message above.
pause
exit /b %RESULT%
