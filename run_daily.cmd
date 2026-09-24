@echo off
rem Run run_daily.sh through Git Bash. Double-click friendly.
rem Keep this file ASCII-only: cmd.exe reads .cmd with the OEM code page.
setlocal

set "BASH_EXE=D:\GIT\Git\bin\bash.exe"
if not exist "%BASH_EXE%" set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"
if not exist "%BASH_EXE%" set "BASH_EXE=C:\Program Files (x86)\Git\bin\bash.exe"
if not exist "%BASH_EXE%" (
  echo [ERROR] bash.exe not found. Install Git for Windows, or edit BASH_EXE in this file.
  exit /b 1
)

cd /d "%~dp0"
"%BASH_EXE%" run_daily.sh %*
exit /b %ERRORLEVEL%
