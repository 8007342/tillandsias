@echo off
rem Thin cmd wrapper around claude-repeat.ps1 so the script works from cmd OR
rem PowerShell with the same invocation:
rem
rem   .\claude-repeat.bat --wait 30m --skill advance-work-from-plan
rem
rem Translates --wait/--skill long-form flags to PowerShell's -Wait/-Skill
rem (PowerShell binds case-insensitively + accepts either dash form).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-repeat.ps1" %*
