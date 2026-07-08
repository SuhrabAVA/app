@echo off
rem Claude Code hook dispatcher: %1 = script name in .claude\helpers,
rem %2 = hook command passed to the script. Replaces the inline
rem   cmd /c "IF EXIST "..." (node ...) ELSE (node ...)"
rem wrappers whose unescaped nested quotes made cmd read the hook-input
rem JSON from stdin as batch commands: every '>' token acted as a
rem redirect and created empty junk files in the repo root.
setlocal
set "SCRIPT=%CLAUDE_PROJECT_DIR%\.claude\helpers\%~1"
if not exist "%SCRIPT%" set "SCRIPT=%USERPROFILE%\.claude\helpers\%~1"
node "%SCRIPT%" %2
