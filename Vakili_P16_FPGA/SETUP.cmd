@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    py -3 -m venv .venv
) else (
    python -m venv .venv
)
if errorlevel 1 exit /b %ERRORLEVEL%
call ".venv\Scripts\activate.bat"
python -m pip install --upgrade pip
if errorlevel 1 exit /b %ERRORLEVEL%
python -m pip install -r requirements.txt
if errorlevel 1 exit /b %ERRORLEVEL%
echo.
echo Setup complete. You can now run RUN_MNIST_TEST.cmd.
