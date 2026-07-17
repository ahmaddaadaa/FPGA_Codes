@echo off
setlocal
set "ROOT=%~dp0"
set "PYTHON=%ROOT%.venv\Scripts\python.exe"
set "MANIFEST=%ROOT%models\exact\manifest.json"
set "VERIFY=%ROOT%host\runtime\scripts\verify_vakili_r1_aware_p16_ethernet.py"
set "LOAD=%ROOT%host\runtime\scripts\load_vakili_r1_aware_p16_ethernet_parameters.py"
if not exist "%PYTHON%" (
    echo Run SETUP.cmd first.
    exit /b 1
)
"%PYTHON%" "%VERIFY%" --test-connect
if errorlevel 1 exit /b %ERRORLEVEL%
"%PYTHON%" "%LOAD%" --manifest "%MANIFEST%"
if errorlevel 1 exit /b %ERRORLEVEL%
"%PYTHON%" "%VERIFY%" --arithmetic exact --manifest "%MANIFEST%" --dataset official-test --sample-count 10000 --progress-every 100 --show-confusion --mnist-download %*
exit /b %ERRORLEVEL%
