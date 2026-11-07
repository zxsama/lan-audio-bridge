@echo off
rem Builds vban-sender.exe with the installed MSVC x64 toolchain. Output: dist\windows\vban-sender.exe
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
set "OUT=%HERE%..\..\dist\windows"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSDIR="
for /f "usebackq delims=" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo MSVC x64 tools not found & exit /b 1)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist "%OUT%" mkdir "%OUT%"
cl /nologo /std:c++17 /O2 /W4 /WX /EHsc /MT /DUNICODE /D_UNICODE "%HERE%vban_sender.cpp" /Fo"%OUT%\\" /Fe"%OUT%\vban-sender.exe" /link /SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup || exit /b 1
del "%OUT%\vban_sender.obj" 2>nul
echo built %OUT%\vban-sender.exe
