@echo off
REM ---------------------------------------------------------------------------
REM Register Local Media Center to start at user logon.
REM
REM Uses Task Scheduler with /RL LIMITED (normal user rights) so no admin
REM password is needed. ONLOGON is used rather than ONSTART for the same
REM reason: ONSTART requires elevation.
REM
REM ASCII only on purpose - see run.cmd for why.
REM ---------------------------------------------------------------------------

setlocal
set "TASK=MediaCenter"
set "HERE=%~dp0"
for %%I in ("%HERE%..") do set "PKG=%%~fI"
set "EXE=%PKG%\mediacenter.exe"
set "RUNNER=%HERE%run.cmd"

if not exist "%EXE%" (
  echo [ERROR] Cannot find "%EXE%" 1>&2
  echo         Unzip the whole package so that service\ sits next to mediacenter.exe. 1>&2
  exit /b 1
)

REM Task Scheduler's /TR argument does not survive spaces in the path without
REM quote-escaping that varies by Windows version. Warn instead of shipping a
REM fragile escape: the user can still install, they just need to know why the
REM task might not launch later.
echo "%PKG%" | findstr /C:" " >nul
if not errorlevel 1 (
  echo [WARN] The package path contains a space:
  echo        %PKG%
  echo        Task Scheduler may fail to launch it. If the server does not
  echo        start at logon, move this folder somewhere without spaces
  echo        ^(for example C:\mediacenter^) and run this script again.
  echo.
)

schtasks /Create /TN "%TASK%" /TR "%RUNNER%" /SC ONLOGON /RL LIMITED /F
if errorlevel 1 (
  echo [ERROR] schtasks failed to create the task. 1>&2
  exit /b 1
)

echo Installed autostart: scheduled task "%TASK%" runs at logon
echo   Logs  : %USERPROFILE%\.mediacenter\logs\mediacenter.log
echo   Remove: %HERE%uninstall.cmd
echo.
echo Note: a console window will appear at logon and stay open while the
echo       server runs. To hide it, open Task Scheduler, edit this task and
echo       check "Run whether user is logged on or not" (that one needs admin).
