@echo off
setlocal
set LOGFILE=C:\Windows\Temp\wazuh-agent-install.log
set MSI=\fileserver\software\wazuh\wazuh-agent.msi
set WAZUH_MANAGER=wazuh-lb.lab.local
set WAZUH_REGISTRATION_SERVER=wazuh-lb.lab.local
set WAZUH_AGENT_GROUP=windows
set WAZUH_REGISTRATION_PASSWORD=ChangeMeEnrollPass

echo [%DATE% %TIME%] Starting Wazuh agent deployment check >> "%LOGFILE%"

sc query WazuhSvc >nul 2>&1
if %ERRORLEVEL%==0 (
    echo [%DATE% %TIME%] WazuhSvc already present, skipping install >> "%LOGFILE%"
    goto :ensure_running
)

echo [%DATE% %TIME%] Installing from %MSI% >> "%LOGFILE%"
msiexec.exe /i "%MSI%" /q ^
    WAZUH_MANAGER="%WAZUH_MANAGER%" ^
    WAZUH_REGISTRATION_SERVER="%WAZUH_REGISTRATION_SERVER%" ^
    WAZUH_AGENT_GROUP="%WAZUH_AGENT_GROUP%" ^
    WAZUH_REGISTRATION_PASSWORD="%WAZUH_REGISTRATION_PASSWORD%" >> "%LOGFILE%" 2>&1

echo [%DATE% %TIME%] msiexec exit code %ERRORLEVEL% >> "%LOGFILE%"

:ensure_running
sc query WazuhSvc | find "RUNNING" >nul 2>&1
if not %ERRORLEVEL%==0 (
    echo [%DATE% %TIME%] Starting WazuhSvc >> "%LOGFILE%"
    net start WazuhSvc >> "%LOGFILE%" 2>&1
)
echo [%DATE% %TIME%] Done >> "%LOGFILE%"
endlocal
