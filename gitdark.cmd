@echo off
pwsh -NoLogo -NoProfile -File "%~dp0gitdark.ps1" %*
exit /b %errorlevel%
