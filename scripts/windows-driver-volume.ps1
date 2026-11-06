# Copyright (c) 2026 LAN Audio Bridge contributors.
# SPDX-License-Identifier: MIT
# Narrow elevated helper. No caller-controlled file paths or native commands.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Enable', 'Restore')][string]$Action)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LanAudioBridge\WindowsAudio'
$resultPath = Join-Path $stateRoot 'driver-volume-result.json'
$originalPath = Join-Path $stateRoot 'driver-volume-original.json'
$result = [ordered]@{ Schema = 1; Action = $Action; Succeeded = $false; Error = $null }
$exitCode = 1
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        -not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Use 64-bit PowerShell on Windows x64.'
    }
    Import-Module (Join-Path $PSScriptRoot 'windows\Voicemeeter.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'windows\DriverOptions.psm1') -Force
    $directory = Get-VoicemeeterDirectory
    if (-not $directory) { throw 'The installed Voicemeeter directory was not found.' }
    $panel = Join-Path $directory 'VBVoicemeeterVAIO_ControlPanel.exe'
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    if ($Action -eq 'Enable') {
        # The immutable first snapshot belongs to Restore; retries receive their own transaction backup.
        $transactionPath = if (Test-Path -LiteralPath $originalPath) {
            Join-Path $stateRoot ('driver-volume-transaction-' + [Guid]::NewGuid().ToString('N') + '.json')
        } else { $originalPath }
        $change = Enable-DriverWindowsVolumeControl -ControlPanelPath $panel -BackupPath $transactionPath
        $result['After'] = $change.After
    } else {
        if (-not (Test-Path -LiteralPath $originalPath -PathType Leaf)) {
            throw 'The original native driver option backup is missing.'
        }
        $snapshot = Get-Content -LiteralPath $originalPath -Raw | ConvertFrom-Json
        $result['After'] = Restore-DriverVolumeControlState -ControlPanelPath $panel -Snapshot $snapshot
    }
    $result.Succeeded = $true
    $exitCode = 0
} catch {
    $result.Error = $_.Exception.Message
} finally {
    $result['Finished'] = (Get-Date).ToString('o')
    try {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        $temporary = $resultPath + '.tmp'
        [IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $resultPath -Force
    } catch {
        Write-Error -Message ('Could not save native driver option result: ' + $_.Exception.Message) -ErrorAction Continue
        $exitCode = 1
    }
}
exit $exitCode
