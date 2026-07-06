@echo off
REM Automatically commits and pushes all changes to GitHub (Windows)
REM Usage: scripts\git-auto-push.bat [commit-message]

echo Checking git status...

REM Check if there are changes
git status --porcelain > temp_status.txt
set /p STATUS=<temp_status.txt
del temp_status.txt

if "%STATUS%"=="" (
    echo No changes to commit
    exit /b 0
)

echo Changes detected:
git status --short

REM Get commit message or use default
set COMMIT_MESSAGE=%*
if "%COMMIT_MESSAGE%"=="" (
    set COMMIT_MESSAGE=Auto-commit: %date% %time%
)

echo.
echo Adding all changes...
git add .

echo.
echo Committing with message: "%COMMIT_MESSAGE%"
git commit -m "%COMMIT_MESSAGE%"

echo.
echo Pushing to GitHub...
git push

echo.
echo Successfully pushed all changes to GitHub!
