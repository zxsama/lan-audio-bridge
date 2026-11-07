# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
# SPDX-License-Identifier: MIT
# Windows PowerShell 5.1 and PowerShell 7, Windows x64.
# Native low-latency sender: WASAPI loopback -> VBAN, replacing Voicemeeter's network output.
[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Status', 'Start', 'Stop', 'Restore')]
    [string]$Action = 'Setup',
    [string]$Address,
    [string[]]$Prefer,
    [int]$Port = 6980,
    [string]$StreamName = 'Windows',
    [string]$SenderPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'windows\Sender.psm1') -Force
Add-Type -Path (Join-Path $PSScriptRoot 'windows\AudioInterop.cs')
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LanAudioBridge\Sender'
$exe = Join-Path $stateRoot 'vban-sender.exe'
$configPath = Join-Path $stateRoot 'sender.conf'
$logPath = Join-Path $stateRoot 'sender.log'
$statePath = Join-Path $stateRoot 'original.json'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$senderRunName = 'LanAudioBridgeSender'
$voicemeeterRunName = 'LanAudioBridgeAudio'  # written by windows-audio.ps1
$endpoints = [LanAudioBridge.WindowsAudio.Endpoints]

function Get-RunValue([string]$Name) {
    $entry = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
    if ($entry -and $entry.PSObject.Properties[$Name]) { return [pscustomobject]@{ Exists = $true; Value = [string]$entry.$Name } }
    return [pscustomobject]@{ Exists = $false; Value = $null }
}

function Set-RunValue([string]$Name, $Value) {
    if ($Value.Exists) {
        New-Item -Path $runKey -Force | Out-Null
        New-ItemProperty -LiteralPath $runKey -Name $Name -Value $Value.Value -PropertyType String -Force | Out-Null
    } else { Remove-ItemProperty -LiteralPath $runKey -Name $Name -ErrorAction SilentlyContinue }
}

# The sender is a windowless (GUI-subsystem) program: run it explicitly and wait.
function Invoke-SenderTool([string[]]$Arguments) {
    $out = [IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $Arguments -RedirectStandardOutput $out -WindowStyle Hidden -Wait -PassThru
        $text = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Lines = @($text -split "`r?`n" | Where-Object { $_ }) }
    } finally { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
}

function Get-SenderProcess {
    @(Get-Process -Name 'vban-sender' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ([IO.Path]::GetFullPath($_.Path) -ieq [IO.Path]::GetFullPath($exe)) } catch { $false } })
}

function Stop-Sender {
    if (-not @(Get-SenderProcess).Count) { return }
    $null = Invoke-SenderTool @('--stop')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-SenderProcess).Count -and $watch.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
    Get-SenderProcess | Stop-Process -Force
}

function Start-Sender {
    $offset = if (Test-Path -LiteralPath $logPath) { (Get-Item -LiteralPath $logPath).Length } else { 0 }
    Start-Process -FilePath $exe -ArgumentList @('--config', ('"' + $configPath + '"')) -WindowStyle Hidden | Out-Null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 200
        $fresh = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 } else { '' }
        if ($fresh.Length -lt $offset) { $offset = 0 }
        $capture = $fresh.Substring([Math]::Min($offset, $fresh.Length)) -split "`n" | Where-Object { $_ -match '"event":"(capture|error)"' } | Select-Object -Last 1
    } while (-not $capture -and $watch.Elapsed.TotalSeconds -lt 6)
    if (-not $capture) { throw 'The sender did not start capturing. See ' + $logPath }
    if ($capture -match '"event":"error"') { throw 'The sender reported an error: ' + $capture }
    return ($capture | ConvertFrom-Json)
}

# Voicemeeter is optional. When present, its network output must be off: the NAS
# accepts one VBAN stream per source address and name.
function Invoke-Voicemeeter([scriptblock]$Body) {
    $process = @(Get-Process -Name 'voicemeeter*' -ErrorAction SilentlyContinue)
    if (-not $process.Count) { return $null }
    Import-Module (Join-Path $PSScriptRoot 'windows\Voicemeeter.psm1') -Force
    $remote = [LanAudioBridge.WindowsAudio.VoicemeeterRemote]::new((Join-Path (Get-VoicemeeterDirectory) 'VoicemeeterRemote64.dll'))
    try {
        if ($remote.Login() -ne 0) { throw 'Voicemeeter is running but its remote API is not ready.' }
        Wait-Voicemeeter $remote
        return (& $Body $remote)
    } finally { $remote.Dispose() }
}

function Set-VoicemeeterVban($Remote, [float]$Value) {
    $Remote.SetFloat('vban.Enable', $Value)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Milliseconds 150; $null = $Remote.Dirty() } while ($Remote.GetFloat('vban.Enable') -ne $Value -and $watch.Elapsed.TotalSeconds -lt 8)
    if ($Remote.GetFloat('vban.Enable') -ne $Value) { throw 'Voicemeeter did not apply the VBAN setting.' }
}

function Find-SenderSource {
    $candidates = @()
    if ($SenderPath) { $candidates += $SenderPath }
    $candidates += @((Join-Path $PSScriptRoot 'windows\vban-sender.exe'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\windows\vban-sender.exe'))
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path } }
    throw 'vban-sender.exe was not found. Build it with native\windows\build.cmd or use the complete package.'
}

function Restore-Original {
    if (-not (Test-Path -LiteralPath $statePath)) { Write-Output 'Nothing to restore.'; return }
    $original = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Stop-Sender
    Set-RunValue $senderRunName $original.SenderRun
    Set-RunValue $voicemeeterRunName $original.VoicemeeterRun
    $active = @($endpoints::ListRender() | Where-Object Active | ForEach-Object Id)
    $missing = @($original.Defaults | Where-Object { $_.Id -and $active -notcontains $_.Id })
    foreach ($endpoint in $original.Defaults) {
        if ($endpoint.Id -and $active -contains $endpoint.Id) { $endpoints::SetDefault($endpoint.Id, [int]$endpoint.Role) }
    }
    if ($null -ne $original.VbanEnable) {
        $null = Invoke-Voicemeeter { param($r) Set-VoicemeeterVban $r ([float]$original.VbanEnable) }
    }
    Remove-Item -LiteralPath $statePath -Force
    if ($missing.Count) { Write-Warning 'An original playback device is not present; its default role was left unchanged.' }
    Write-Output 'Original startup entries, default playback devices and Voicemeeter network output were restored.'
}

switch ($Action) {
    'Setup' {
        if (-not $Address) { $Address = (Read-Host 'NAS IPv4 address').Trim() }
        $source = Find-SenderSource
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
        Stop-Sender
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($exe)) { Copy-Item -LiteralPath $source -Destination $exe -Force }
        $listing = Invoke-SenderTool @('--list')
        if ($listing.ExitCode -ne 0) { throw 'The sender could not list playback devices.' }
        $list = ConvertFrom-SenderEndpointList $listing.Lines
        # `powershell -File` passes "-Prefer a,b" as one string; endpoint IDs never contain commas.
        $Prefer = @($Prefer | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $Prefer.Count) {
            $parents = @{}
            foreach ($endpoint in $endpoints::ListRender()) { $parents[[string]$endpoint.Id] = [string]$endpoint.ParentDevice }
            $Prefer = @(Select-SenderEndpoints $list $parents | ForEach-Object id)
        }
        if (-not $Prefer.Count) { throw 'No suitable playback device was found. Connect a wired output or pass -Prefer.' }
        foreach ($id in $Prefer) { if (-not ($list | Where-Object id -eq $id)) { throw "Preferred endpoint is not active: $id" } }
        $lines = New-SenderConfigLines $Address $Port $StreamName $Prefer $logPath
        $command = New-SenderRunCommand $exe $configPath
        $firstSetup = -not (Test-Path -LiteralPath $statePath)
        if ($firstSetup) {
            $vban = Invoke-Voicemeeter { param($r) $r.GetFloat('vban.Enable') }
            $original = [ordered]@{ Schema = 1; Time = (Get-Date).ToString('o')
                Defaults = @(0..2 | ForEach-Object { [pscustomobject]@{ Role = $_; Id = $endpoints::GetDefault($_) } })
                SenderRun = Get-RunValue $senderRunName; VoicemeeterRun = Get-RunValue $voicemeeterRunName; VbanEnable = $vban }
            $original | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
        }
        try {
            [IO.File]::WriteAllLines($configPath, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
            Set-RunValue $voicemeeterRunName ([pscustomobject]@{ Exists = $false; Value = $null })
            $null = Invoke-Voicemeeter { param($r) Set-VoicemeeterVban $r 0 }
            Set-RunValue $senderRunName ([pscustomobject]@{ Exists = $true; Value = $command })
            $capture = Start-Sender
            Start-Sleep -Milliseconds 800
            $current = $endpoints::GetDefault(0)
            $name = ($list | Where-Object id -eq $current | Select-Object -First 1).name
            Write-Output ("Sending to {0}:{1} as '{2}'. Capturing '{3}' (engine period {4} frames)." -f $Address, $Port, $StreamName, $capture.device, $capture.keeper_frames)
            Write-Output ('Default playback device: ' + $name)
            Write-Output ('Preference order: ' + (($Prefer | ForEach-Object { $p = $_; ($list | Where-Object id -eq $p).name }) -join ' > '))
        } catch {
            if ($firstSetup) { try { Restore-Original | Out-Null } catch { Write-Warning "Rollback failed: $($_.Exception.Message)" } }
            throw
        }
    }
    'Status' {
        $running = @(Get-SenderProcess)
        Write-Output ('Sender running: ' + [bool]$running.Count + $(if ($running.Count) { " (pid $($running[0].Id))" } else { '' }))
        if (Test-Path -LiteralPath $configPath) { Write-Output ('Configuration: ' + ((Get-Content -LiteralPath $configPath) -join ' ')) }
        Write-Output ('Startup entry: ' + (Get-RunValue $senderRunName).Exists)
        Write-Output ('Default playback device: ' + $endpoints::GetDefault(0))
        if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 200 -Encoding UTF8 | Where-Object { $_ -match '"event":"(capture|statistics|error|default_endpoint)"' } | Select-Object -Last 4 }
        $vban = Invoke-Voicemeeter { param($r) $r.GetFloat('vban.Enable') }
        if ($null -ne $vban) { Write-Output ('Voicemeeter VBAN output enabled: ' + ($vban -ne 0)) }
    }
    'Start' { if (-not (Test-Path -LiteralPath $configPath)) { throw 'Run Setup first.' }; Stop-Sender; $null = Start-Sender; Write-Output 'Sender started.' }
    'Stop' { Stop-Sender; Write-Output 'Sender stopped (startup entry unchanged).' }
    'Restore' { Restore-Original }
}
