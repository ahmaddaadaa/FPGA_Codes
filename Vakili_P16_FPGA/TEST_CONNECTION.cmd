@echo off
setlocal
set "ROOT=%~dp0"
set "PYTHON=%ROOT%.venv\Scripts\python.exe"
if not exist "%PYTHON%" (
    echo Run SETUP.cmd first.
    exit /b 1
)
"%PYTHON%" "%ROOT%host\runtime\scripts\verify_vakili_r1_aware_p16_ethernet.py" --test-connect %*
exit /b %ERRORLEVEL%
