@echo off
REM EvoGit Desktop Launcher for Windows
REM This script starts the EvoGit dashboard in desktop mode.

set SECRET_KEY_BASE=EvoGitDesktopLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890
set PHX_SERVER=true
set EVOGIT_DESKTOP=1
set EVOGIT_DESKTOP_PORT=4100
set RELEASE_DISTRIBUTION=none

"%~dp0release\bin\evogit.cmd" start
