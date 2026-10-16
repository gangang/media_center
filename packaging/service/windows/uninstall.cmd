@echo off
REM ---------------------------------------------------------------------------
REM Remove the logon task. Does not touch the data directory
REM (%USERPROFILE%\.mediacenter) - your index and uploaded photos stay.
REM
REM ASCII only on purpose - see run.cmd for why.
REM ---------------------------------------------------------------------------

setlocal
set "TASK=MediaCenter"

schtasks /Query /TN "%TASK%" >nul 2>&1
if errorlevel 1 (
  echo No scheduled task named "%TASK%" was found.
  echo It may never have been installed, or it was already removed.
  exit /b 0
)

schtasks /Delete /TN "%TASK%" /F
if errorlevel 1 (
  echo [ERROR] Could not delete the task. 1>&2
  exit /b 1
)

echo Removed autostart: scheduled task "%TASK%"
echo Data directory left untouched: %USERPROFILE%\.mediacenter
