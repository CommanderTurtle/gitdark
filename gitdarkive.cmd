@echo off
pwsh -NoLogo -NoProfile -File "%~dp0gitdark.ps1" gitdarkive %*
exit /b %errorlevel%
