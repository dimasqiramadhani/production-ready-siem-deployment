$targets = @("win-agent-01.lab.local", "win-agent-02.lab.local")
$msiSource = "\fileserver\software\wazuh\wazuh-agent.msi"
$cred = Get-Credential   # domain admin

Invoke-Command -ComputerName $targets -Credential $cred -ScriptBlock {
    param($msiSource)

    $log = "C:\Windows\Temp\wazuh-agent-install.log"
    "$(Get-Date) start on $env:COMPUTERNAME" | Out-File -Append $log

    if (Get-Service -Name WazuhSvc -ErrorAction SilentlyContinue) {
        "$(Get-Date) WazuhSvc present, skipping install" | Out-File -Append $log
    } else {
        $local = "C:\Windows\Temp\wazuh-agent.msi"
        Copy-Item -Path $msiSource -Destination $local -Force

        $args = @(
            "/i", $local, "/q",
            "WAZUH_MANAGER=wazuh-lb.lab.local",
            "WAZUH_REGISTRATION_SERVER=wazuh-lb.lab.local",
            "WAZUH_AGENT_GROUP=windows",
            "WAZUH_REGISTRATION_PASSWORD=ChangeMeEnrollPass"
        )
        $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
        "$(Get-Date) msiexec exit $($p.ExitCode)" | Out-File -Append $log
    }

    if ((Get-Service WazuhSvc).Status -ne "Running") {
        Start-Service WazuhSvc
    }
    "$(Get-Date) service status $((Get-Service WazuhSvc).Status)" | Out-File -Append $log
} -ArgumentList $msiSource

foreach ($t in $targets) {
    Write-Host "==== $t ===="
    Invoke-Command -ComputerName $t -Credential $cred -ScriptBlock {
        Get-Content C:\Windows\Temp\wazuh-agent-install.log -Tail 20
    }
}
