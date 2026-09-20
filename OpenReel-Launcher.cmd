@echo off
setlocal

rem  OpenReel Dev launcher entry point.
rem    OpenReel-Launcher.cmd             open the menu (in Windows Terminal when available)
rem    OpenReel-Launcher.cmd <action>    run one action and exit: start stop restart
rem                                      status build upstream doctor

rem  PATH self-heal: shortcut and scheduled launches can get a thin PATH.
set "PATH=%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\WindowsPowerShell\v1.0;%PATH%"

if /i "%~1"=="__inwt" goto :menu_in_wt
if not "%~1"=="" goto :run
if defined WT_SESSION goto :run

rem  Double-click: reopen in a Windows Terminal tab for full colour. wt options
rem  must come before the new-tab subcommand. Fall through when wt is missing.
where wt.exe >nul 2>&1 || goto :run
rem  --suppressApplicationTitle keeps the tab named OpenReel: child tools rename
rem  the console while they run and never set it back.
start "" wt.exe -w -1 --size 88,30 new-tab --title "OpenReel" --suppressApplicationTitle cmd /d /c call "%~f0" __inwt
exit /b 0

:menu_in_wt
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\launcher\OpenReel-Launcher.ps1"
set "RC=%ERRORLEVEL%"
rem  This tab closes when cmd exits, so hold it open after any failure.
if not "%RC%"=="0" (
    echo.
    pause
)
exit /b %RC%

:run
set "MENU="
if "%~1"=="" set "MENU=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\launcher\OpenReel-Launcher.ps1" %*
set "RC=%ERRORLEVEL%"

rem  Keep the window open long enough to read what happened: always on failure,
rem  and after a one-shot action when this window was opened for this file (a
rem  double-click). Quitting the menu needs no pause. Set OPENREEL_NO_PAUSE=1
rem  for unattended runs.
if not "%OPENREEL_NO_PAUSE%"=="" goto :done
if not "%RC%"=="0" goto :hold
if defined MENU goto :done
rem  Full path to find.exe - a Unix find earlier on PATH would shadow it.
echo %CMDCMDLINE% | "%SystemRoot%\System32\find.exe" /i "%~nx0" >nul || goto :done

:hold
echo.
pause

:done
exit /b %RC%
