@echo off
REM ---------------------------------------------------------------------------
REM Launcher used by the scheduled task.
REM
REM Its only job is to start the server with its output going to a log file.
REM Task Scheduler cannot redirect output itself, so the redirection has to
REM happen somewhere - doing it here keeps the /TR argument in install.cmd
REM down to a single simple path instead of a nest of escaped quotes.
REM
REM ASCII only on purpose: .cmd files run under the OEM codepage (usually GBK on
REM Chinese Windows), so UTF-8 Chinese text in here would render as garbage.
REM ---------------------------------------------------------------------------

setlocal
set "HERE=%~dp0"
set "PKG=%HERE%.."
set "LOG=%USERPROFILE%\.mediacenter\logs"

if not exist "%LOG%" mkdir "%LOG%"

REM -scan runs an incremental index pass at startup. It only does real work for
REM files whose size or mtime changed, so it is cheap and it means photos added
REM while the machine was off show up as soon as it is back.
"%PKG%\mediacenter.exe" -scan >> "%LOG%\mediacenter.log" 2>&1
