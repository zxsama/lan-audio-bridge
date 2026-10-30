[CmdletBinding()]
param(
    [ValidateSet('Start', 'Status', 'Stop')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$wslRoot = (& wsl.exe -d Ubuntu -u root -- wslpath -a $projectRoot.Replace('\', '/')).Trim()
if ($LASTEXITCODE -ne 0 -or -not $wslRoot) { throw 'Cannot resolve the project path in Ubuntu WSL.' }
$composeFile = "$wslRoot/compose.local.yaml"
$helperFile = "$wslRoot/scripts/local-keepalive.py"
$composeArgs = @('-d', 'Ubuntu', '-u', 'root', '--', 'docker', 'compose', '-p', 'lan-audio-bridge-local', '-f', $composeFile)

function Invoke-LocalCompose {
    param([string[]]$CommandArgs)
    & wsl.exe @composeArgs @CommandArgs
    if ($LASTEXITCODE -ne 0) { throw "Local Compose failed: $($CommandArgs -join ' ')" }
}

switch ($Action) {
    'Start' {
        Invoke-LocalCompose -CommandArgs @('up', '-d', '--wait', '--wait-timeout', '120')
        $helperStatus = & wsl.exe -d Ubuntu -u root -- python3 $helperFile --status
        if ($LASTEXITCODE -ne 0) {
            # Start-Process joins ArgumentList into a command line, so quote the path explicitly.
            $helperArguments = '-d Ubuntu -u root -- python3 "' + $helperFile + '"'
            Start-Process -FilePath 'wsl.exe' -ArgumentList $helperArguments -WindowStyle Hidden | Out-Null
        }
        $ready = $false
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $helperStatus = & wsl.exe -d Ubuntu -u root -- python3 $helperFile --status
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { throw 'The demo started but its WSL keepalive did not start. Run Status or Stop to inspect/clean up.' }
        Write-Output $helperStatus
        Invoke-LocalCompose -CommandArgs @('ps')
        Write-Output 'DLNA descriptor: http://127.0.0.1:49494/description.xml'
    }
    'Status' {
        Invoke-LocalCompose -CommandArgs @('ps', '--all')
        & wsl.exe -d Ubuntu -u root -- python3 $helperFile --status
    }
    'Stop' {
        Invoke-LocalCompose -CommandArgs @('down', '--timeout', '20')
        # The helper exits when this container is gone; never stop WSL or other sessions.
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            $helperStatus = & wsl.exe -d Ubuntu -u root -- python3 $helperFile --status
            if ($LASTEXITCODE -ne 0) { Write-Output $helperStatus; break }
            Start-Sleep -Milliseconds 500
        }
        if ($LASTEXITCODE -eq 0) { throw 'The container stopped but its keepalive has not exited yet.' }
        Write-Output 'Local demo stopped; local-data is retained.'
    }
}
