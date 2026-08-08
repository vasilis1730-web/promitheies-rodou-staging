@echo off
setlocal EnableExtensions
cd /d "%~dp0"

where.exe powershell.exe >nul 2>&1
if not errorlevel 1 goto use_windows_powershell

where.exe pwsh.exe >nul 2>&1
if not errorlevel 1 goto use_powershell_core

where.exe node.exe >nul 2>&1
if not errorlevel 1 goto use_node

where.exe py.exe >nul 2>&1
if not errorlevel 1 goto use_py

where.exe python.exe >nul 2>&1
if not errorlevel 1 goto use_python

echo.
echo ERROR: No supported local server was found.
echo Windows PowerShell, Node.js, or Python is required.
echo.
pause
exit /b 1

:use_windows_powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0local-server.ps1"
if errorlevel 1 goto server_failed
goto done

:use_powershell_core
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0local-server.ps1"
if errorlevel 1 goto server_failed
goto done

:use_node
start "" "http://127.0.0.1:8080/index.html"
node.exe "%~dp0local-server.mjs"
if errorlevel 1 goto server_failed
goto done

:use_py
start "" "http://127.0.0.1:8080/index.html"
py.exe -m http.server 8080 --bind 127.0.0.1 --directory "%~dp0"
if errorlevel 1 goto server_failed
goto done

:use_python
start "" "http://127.0.0.1:8080/index.html"
python.exe -m http.server 8080 --bind 127.0.0.1 --directory "%~dp0"
if errorlevel 1 goto server_failed
goto done

:server_failed
echo.
echo ERROR: The local server did not start.
echo Close any older server window using port 8080 and try again.
echo.
pause
exit /b 1

:done
endlocal
