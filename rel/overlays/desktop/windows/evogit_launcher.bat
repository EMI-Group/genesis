@echo off
REM Genesis Desktop Launcher for Windows
REM This script starts the Genesis dashboard in desktop mode.

set SECRET_KEY_BASE=EvoGitDesktopLocalSecretKeyBaseDoNotUseInProduction2025abcdef1234567890
set PHX_SERVER=true
set EVOGIT_DESKTOP=1
set PORT=4100
set EVOGIT_DESKTOP_PORT=4100
set RELEASE_DISTRIBUTION=none

"%~dp0release\bin\evogit.cmd" start
