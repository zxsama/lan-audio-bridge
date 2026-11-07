# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
# SPDX-License-Identifier: MIT
# Windows PowerShell 5.1 and PowerShell 7, Windows x64.
# One-click Windows setup: low-latency drivers, a clearly named NAS output, the
# native WASAPI-loopback VBAN sender with autostart, and retirement of the older
# Voicemeeter configuration. Restore reverts every recorded change.
[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Status', 'Start', 'Stop', 'Restore', 'Elevated')]
    [string]$Action = 'Setup',
    [string]$Address,
    [string[]]$Prefer,
    [int]$Port = 6980,
    [string]$StreamName = 'Windows',
    [ValidateSet('Ask', 'Yes', 'No')]
    [string]$Drivers = 'Ask',
    [string]$Name,
    [string]$SenderPath,
    [string]$PlanPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'windows\Sender.psm1') -Force
if (-not ('LanAudioBridge.WindowsAudio.Endpoints' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'windows\AudioInterop.cs') }
$endpoints = [LanAudioBridge.WindowsAudio.Endpoints]
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LanAudioBridge\Sender'
$exe = Join-Path $stateRoot 'vban-sender.exe'
$configPath = Join-Path $stateRoot 'sender.conf'
$logPath = Join-Path $stateRoot 'sender.log'
$statePath = Join-Path $stateRoot 'original.json'
$legacyRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LanAudioBridge\WindowsAudio'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$senderRunName = 'LanAudioBridgeSender'
$legacyRunName = 'LanAudioBridgeAudio'   # former Voicemeeter-based setup
# Default names (Chinese "NAS audio" / "(backup)") are built from code points so this file stays ASCII.
$defaultName = 'NAS ' + [string][char]0x97F3 + [char]0x9891
$backupSuffix = [string][char]0xFF08 + [char]0x5907 + [char]0x7528 + [char]0xFF09
if (-not $Name) { $Name = $defaultName }

# ---------------------------------------------------------------- utilities
function Test-Administrator {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    # Schema 1 (sender-only) lacked driver, name and visibility records.
    foreach ($field in @('Drivers', 'Descriptions', 'Hidden')) {
        if (-not $state.PSObject.Properties[$field]) { $state | Add-Member -NotePropertyName $field -NotePropertyValue @() }
    }
    if (-not $state.PSObject.Properties['VoicemeeterWasRunning']) { $state | Add-Member -NotePropertyName VoicemeeterWasRunning -NotePropertyValue $false }
    $state.Schema = 2
    return $state
}

function Write-State($State) {
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    [IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
}

function Get-RunValue([string]$RunName) {
    $entry = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
    if ($entry -and $entry.PSObject.Properties[$RunName]) { return [pscustomobject]@{ Exists = $true; Value = [string]$entry.$RunName } }
    return [pscustomobject]@{ Exists = $false; Value = $null }
}

function Set-RunValue([string]$RunName, $Value) {
    if ($Value -and $Value.Exists) {
        New-Item -Path $runKey -Force | Out-Null
        New-ItemProperty -LiteralPath $runKey -Name $RunName -Value $Value.Value -PropertyType String -Force | Out-Null
    } else { Remove-ItemProperty -LiteralPath $runKey -Name $RunName -ErrorAction SilentlyContinue }
}

# The sender is a windowless program: run it explicitly and wait for tool actions.
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
        $text = if (Test-Path -LiteralPath $logPath) { (Get-Content -LiteralPath $logPath -Raw -Encoding UTF8) } else { '' }
        if (-not $text) { $text = '' }
        if ($text.Length -lt $offset) { $offset = 0 }
        $line = $text.Substring([Math]::Min($offset, $text.Length)) -split "`n" | Where-Object { $_ -match '"event":"(capture|error)"' } | Select-Object -Last 1
    } while (-not $line -and $watch.Elapsed.TotalSeconds -lt 8)
    if (-not $line) { throw 'The sender did not start capturing. See ' + $logPath }
    if ($line -match '"event":"error"') { throw 'The sender reported an error: ' + $line }
    return ($line | ConvertFrom-Json)
}

function Find-SenderSource {
    $candidates = @()
    if ($SenderPath) { $candidates += $SenderPath }
    $candidates += @((Join-Path $PSScriptRoot 'windows\vban-sender.exe'), (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\windows\vban-sender.exe'))
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path } }
    if (Test-Path -LiteralPath $exe) { return $exe }
    throw 'vban-sender.exe was not found. Build it with native\windows\build.cmd or use the complete package.'
}

function Get-Endpoints {
    $listing = Invoke-SenderTool @('--list')
    if ($listing.ExitCode -ne 0) { throw 'The sender could not list playback devices.' }
    $list = ConvertFrom-SenderEndpointList $listing.Lines
    $parents = @{}
    foreach ($endpoint in $endpoints::ListRender()) { $parents[[string]$endpoint.Id] = [string]$endpoint.ParentDevice }
    return [pscustomobject]@{ List = $list; Parents = $parents }
}

function Get-AudioDevices {
    foreach ($device in @(Get-PnpDevice -Class MEDIA -PresentOnly -ErrorAction SilentlyContinue)) {
        $properties = @{}
        foreach ($p in @(Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_DriverProvider, DEVPKEY_Device_DriverInfPath, DEVPKEY_Device_HardwareIds, DEVPKEY_Device_CompatibleIds -ErrorAction SilentlyContinue)) {
            if ($p.PSObject.Properties['Data'] -and $p.PSObject.Properties['KeyName']) { $properties[$p.KeyName] = $p.Data }
        }
        [pscustomobject]@{ InstanceId = $device.InstanceId; Name = $device.FriendlyName; Status = [string]$device.Status
            Provider = [string]$properties['DEVPKEY_Device_DriverProvider']; Inf = [string]$properties['DEVPKEY_Device_DriverInfPath']
            HardwareIds = @($properties['DEVPKEY_Device_HardwareIds']); CompatibleIds = @($properties['DEVPKEY_Device_CompatibleIds']) }
    }
}

# Voicemeeter is optional; when present its network output must be off (the NAS
# accepts one VBAN stream per source address and name).
function Get-VoicemeeterDirectory {
    foreach ($directory in @((Join-Path ${env:ProgramFiles(x86)} 'VB\Voicemeeter'), (Join-Path $env:ProgramFiles 'VB\Voicemeeter'))) {
        if ((Test-Path -LiteralPath (Join-Path $directory 'voicemeeter.exe')) -and (Test-Path -LiteralPath (Join-Path $directory 'VoicemeeterRemote64.dll'))) { return $directory }
    }
    return $null
}

function Invoke-Voicemeeter([scriptblock]$Body) {
    $directory = Get-VoicemeeterDirectory
    if (-not $directory -or -not @(Get-Process -Name 'voicemeeter*' -ErrorAction SilentlyContinue).Count) { return $null }
    $remote = [LanAudioBridge.WindowsAudio.VoicemeeterRemote]::new((Join-Path $directory 'VoicemeeterRemote64.dll'))
    try {
        if ($remote.Login() -ne 0) { return $null }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt 10) { try { $null = $remote.Dirty(); if ($remote.Type() -gt 0) { break } } catch { }; Start-Sleep -Milliseconds 150 }
        return (& $Body $remote)
    } finally { $remote.Dispose() }
}

function Set-VoicemeeterVban($Remote, [float]$Value) {
    $Remote.SetFloat('vban.Enable', $Value)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do { Start-Sleep -Milliseconds 150; $null = $Remote.Dirty() } while ($Remote.GetFloat('vban.Enable') -ne $Value -and $watch.Elapsed.TotalSeconds -lt 8)
    if ($Remote.GetFloat('vban.Enable') -ne $Value) { throw 'Voicemeeter did not apply the VBAN setting.' }
}

# --------------------------------------------- administrator-only operations
function Invoke-DriverInstall([string]$HardwareId, [string]$Inf) {
    if (-not ('LanAudioBridge.Setup.NewDev' -as [type])) {
        Add-Type -Namespace LanAudioBridge.Setup -Name NewDev -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("newdev.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern bool UpdateDriverForPlugAndPlayDevicesW(System.IntPtr hwnd, string hardwareId, string infPath, uint flags, out bool reboot);
'@
    }
    $reboot = $false
    $path = if ([IO.Path]::IsPathRooted($Inf)) { $Inf } else { Join-Path $env:WINDIR ('INF\' + $Inf) }
    if (-not [LanAudioBridge.Setup.NewDev]::UpdateDriverForPlugAndPlayDevicesW([IntPtr]::Zero, $HardwareId, $path, 1, [ref]$reboot)) {
        throw ("Driver install failed for {0} (Win32 error {1})." -f $HardwareId, [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
    return $reboot
}

# Runs in the elevated child. Reads a plan, writes results; never touches HKCU.
function Invoke-ElevatedPlan {
    $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $result = [ordered]@{ Drivers = @(); Descriptions = @(); Reboot = $false; Error = $null }
    try {
        # Names first: endpoints of a device disappear when its driver changes.
        foreach ($rename in @($plan.Descriptions)) {
            $original = $endpoints::GetDescription($rename.Id)
            $endpoints::SetDescription($rename.Id, $rename.Text)
            $result.Descriptions += [pscustomobject]@{ Id = $rename.Id; Original = $original; Text = $rename.Text }
        }
        foreach ($driver in @($plan.Drivers)) {
            $reboot = Invoke-DriverInstall $driver.HardwareId $driver.Inf
            $result.Reboot = $result.Reboot -or $reboot
            $result.Drivers += $driver
        }
        if (@($plan.Drivers).Count) { Start-Sleep -Seconds 3 }
    } catch { $result.Error = $_.Exception.Message }
    [IO.File]::WriteAllText($plan.ResultPath, ($result | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
}

# Runs administrator steps in one elevated child process (one UAC prompt).
function Invoke-Elevated($Plan) {
    if (-not @($Plan.Drivers).Count -and -not @($Plan.Descriptions).Count) { return [pscustomobject]@{ Drivers = @(); Descriptions = @(); Reboot = $false; Error = $null } }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    $planFile = Join-Path $stateRoot 'elevated-plan.json'
    $Plan | Add-Member -NotePropertyName ResultPath -NotePropertyValue (Join-Path $stateRoot 'elevated-result.json') -Force
    Remove-Item -LiteralPath $Plan.ResultPath -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($planFile, ($Plan | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    try {
        if (Test-Administrator) { $script:PlanPath = $planFile; Invoke-ElevatedPlan }
        else {
            Write-Host 'Administrator permission is needed for drivers and device names; approve the Windows prompt.'
            $shell = (Get-Process -Id $PID).Path
            $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Action', 'Elevated', '-PlanPath', ('"' + $planFile + '"'))
            try { Start-Process -FilePath $shell -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait | Out-Null }
            catch { throw 'Administrator permission was declined.' }
        }
        if (-not (Test-Path -LiteralPath $Plan.ResultPath)) { throw 'The administrator step did not complete.' }
        return (Get-Content -LiteralPath $Plan.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } finally { Remove-Item -LiteralPath $planFile, $Plan.ResultPath -ErrorAction SilentlyContinue }
}

# ------------------------------------------------------------------- actions
function Invoke-Setup {
    $state = Read-State
    $first = -not $state
    if ($first) {
        $state = [pscustomobject][ordered]@{ Schema = 2; Time = (Get-Date).ToString('o')
            Defaults = @(0..2 | ForEach-Object { [pscustomobject]@{ Role = $_; Id = $endpoints::GetDefault($_) } })
            SenderRun = Get-RunValue $senderRunName; VoicemeeterRun = Get-RunValue $legacyRunName; VbanEnable = $null
            VoicemeeterWasRunning = $false; Drivers = @(); Descriptions = @(); Hidden = @() }
    }
    if (-not $Address -and (Test-Path -LiteralPath $configPath)) {
        $lines = @(Get-Content -LiteralPath $configPath)
        $index = [array]::IndexOf($lines, '--target')
        if ($index -ge 0) { $Address = $lines[$index + 1] }
    }
    if (-not $Address) { $Address = (Read-Host 'NAS IPv4 address').Trim() }
    $null = New-SenderConfigLines $Address $Port $StreamName @() $null  # validate early
    $source = Find-SenderSource
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    Stop-Sender
    if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($exe)) { Copy-Item -LiteralPath $source -Destination $exe -Force }

    # 1. Low-latency class drivers (administrator).
    # Only devices that currently provide an active output can benefit.
    $parents = @($endpoints::ListRender() | Where-Object Active | ForEach-Object { [string]$_.ParentDevice })
    $switch = @(Get-DriverSwitchPlan @(Get-AudioDevices)) | Where-Object { $id = $_.InstanceId; @($parents | Where-Object { $_ -like ('*' + $id) }).Count }
    $switch = @($switch)
    if ($switch.Count -and $Drivers -eq 'Ask') {
        Write-Output 'These audio devices can use a Microsoft driver with a smaller audio engine period (lower latency):'
        $switch | ForEach-Object { Write-Output ("  {0}  ({1} -> {2})" -f $_.Name, $_.OriginalProvider, $_.InboxInf) }
        $answer = Read-Host 'Switch them now? Restore puts the original drivers back. [Y/n]'
        $Drivers = if ($answer -match '^(n|no)$') { 'No' } else { 'Yes' }
    }
    if ($Drivers -ne 'Yes') { $switch = @() }
    if ($switch.Count) {
        $result = Invoke-Elevated ([pscustomobject]@{ Drivers = @($switch | ForEach-Object { [pscustomobject]@{ HardwareId = $_.HardwareId; Inf = $_.InboxInf } }); Descriptions = @() })
        foreach ($done in @($result.Drivers)) {
            $record = $switch | Where-Object HardwareId -eq $done.HardwareId | Select-Object -First 1
            if (-not ($state.Drivers | Where-Object HardwareId -eq $record.HardwareId)) { $state.Drivers = @($state.Drivers) + $record }
        }
        Write-State $state
        if ($result.Error) { throw $result.Error }
        if ($result.Reboot) { Write-Warning 'Windows reports that a restart completes the driver change.' }
        $first = $false  # the state now exists; later failures must not discard it
    }

    # 2. Capture preference: explicit > previous configuration > automatic.
    $found = Get-Endpoints
    $active = @($found.List | ForEach-Object id)
    $Prefer = @($Prefer | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Prefer.Count -and (Test-Path -LiteralPath $configPath)) {
        $lines = @(Get-Content -LiteralPath $configPath)
        $Prefer = @(for ($i = 0; $i -lt $lines.Count - 1; $i++) { if ($lines[$i] -eq '--prefer' -and $active -contains $lines[$i + 1]) { $lines[$i + 1] } })
    }
    if (-not $Prefer.Count) { $Prefer = Select-SenderPreference $found.List $found.Parents }
    if (-not $Prefer.Count) { throw 'No suitable playback device was found. Connect a wired output or pass -Prefer.' }
    foreach ($id in $Prefer) { if ($active -notcontains $id) { throw "Preferred endpoint is not active: $id" } }

    # 3. Name the NAS outputs clearly in Windows Sound settings (administrator).
    $wanted = @{}
    for ($i = 0; $i -lt $Prefer.Count; $i++) { $wanted[$Prefer[$i]] = if ($i -eq 0) { $Name } else { $Name + $backupSuffix } }
    $renames = @()
    foreach ($id in $wanted.Keys) { if ($endpoints::GetDescription($id) -ne $wanted[$id]) { $renames += [pscustomobject]@{ Id = $id; Text = $wanted[$id] } } }
    foreach ($old in @($state.Descriptions)) {  # endpoints no longer used for the NAS get their own name back
        if (-not $wanted.ContainsKey($old.Id) -and $endpoints::ListRender().Id -contains $old.Id) { $renames += [pscustomobject]@{ Id = $old.Id; Text = $old.Original } }
    }
    if ($renames.Count) {
        $result = Invoke-Elevated ([pscustomobject]@{ Drivers = @(); Descriptions = $renames })
        foreach ($done in @($result.Descriptions)) {
            $existing = $state.Descriptions | Where-Object Id -eq $done.Id | Select-Object -First 1
            if (-not $existing) { $state.Descriptions = @($state.Descriptions) + [pscustomobject]@{ Id = $done.Id; Original = $done.Original } }
            elseif ($done.Text -eq $existing.Original) { $state.Descriptions = @($state.Descriptions | Where-Object Id -ne $done.Id) }
        }
        Write-State $state
        if ($result.Error) { Write-Warning ('Device names were not changed: ' + $result.Error) }
    }

    # 4. Retire the Voicemeeter route: one VBAN stream per PC, hide its outputs.
    if ($first) { $state.VbanEnable = Invoke-Voicemeeter { param($r) $r.GetFloat('vban.Enable') } }
    $null = Invoke-Voicemeeter { param($r) Set-VoicemeeterVban $r 0 }
    $running = @(Get-Process -Name 'voicemeeter*' -ErrorAction SilentlyContinue)
    if ($running.Count) { $state.VoicemeeterWasRunning = $true; $running | Stop-Process -Force }
    Set-RunValue $legacyRunName $null
    foreach ($endpoint in @($endpoints::ListRender() | Where-Object { $_.Active -and $_.Name -match 'VB-Audio Voicemeeter' })) {
        $endpoints::SetVisibility($endpoint.Id, $false)
        if (@($state.Hidden) -notcontains $endpoint.Id) { $state.Hidden = @($state.Hidden) + $endpoint.Id }
    }
    if (Test-Path -LiteralPath $legacyRoot) {
        # The former setup's program copy and backups refer to devices that no longer exist.
        $hiddenByLegacy = Join-Path $legacyRoot 'endpoints-original.json'
        if (Test-Path -LiteralPath $hiddenByLegacy) {
            foreach ($id in @((Get-Content -LiteralPath $hiddenByLegacy -Raw | ConvertFrom-Json).Endpoints | ForEach-Object Id)) {
                if ($id -and @($state.Hidden) -notcontains $id) { $state.Hidden = @($state.Hidden) + $id }
            }
        }
        $legacy = Join-Path $legacyRoot 'original.json'
        if (Test-Path -LiteralPath $legacy) { Copy-Item -LiteralPath $legacy -Destination (Join-Path $stateRoot 'voicemeeter-setup-original.json') -Force }
        Remove-Item -LiteralPath $legacyRoot -Recurse -Force
    }
    Write-State $state

    # 5. Sender configuration, autostart and start.
    $lines = New-SenderConfigLines $Address $Port $StreamName $Prefer $logPath
    [IO.File]::WriteAllLines($configPath, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
    Set-RunValue $senderRunName ([pscustomobject]@{ Exists = $true; Value = (New-SenderRunCommand $exe $configPath) })
    $capture = Start-Sender
    Start-Sleep -Milliseconds 800
    $names = @($Prefer | ForEach-Object { $id = $_; ($endpoints::ListRender() | Where-Object Id -eq $id | Select-Object -First 1).Name })
    Write-Output ("Sending to {0}:{1} as '{2}', capturing '{3}' with a {4}-frame engine period." -f $Address, $Port, $StreamName, $capture.device, $capture.keeper_frames)
    Write-Output ('Windows output for the NAS: ' + ($names -join '  >  backup: '))
}

function Invoke-Restore {
    $state = Read-State
    if (-not $state) { Write-Output 'Nothing to restore.'; return }
    Stop-Sender
    Set-RunValue $senderRunName $state.SenderRun
    foreach ($id in @($state.Hidden)) { try { $endpoints::SetVisibility($id, $true) } catch { Write-Warning "Could not show endpoint ${id}: $($_.Exception.Message)" } }
    $present = @($endpoints::ListRender() | ForEach-Object Id)
    $plan = [pscustomobject]@{
        Descriptions = @($state.Descriptions | Where-Object { $present -contains $_.Id } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Text = $_.Original } })
        Drivers = @($state.Drivers | ForEach-Object { [pscustomobject]@{ HardwareId = $_.HardwareId; Inf = $_.OriginalInf } }) }
    $result = Invoke-Elevated $plan
    if ($result.Error) { throw ('Restore incomplete (state kept, run Restore again): ' + $result.Error) }
    if (@($state.Drivers).Count) { Start-Sleep -Seconds 3 }
    $active = @($endpoints::ListRender() | Where-Object Active | ForEach-Object Id)
    foreach ($endpoint in @($state.Defaults)) { if ($endpoint.Id -and $active -contains $endpoint.Id) { $endpoints::SetDefault($endpoint.Id, [int]$endpoint.Role) } }
    if ($state.VoicemeeterWasRunning) {
        $directory = Get-VoicemeeterDirectory
        if ($directory) {
            Start-Process -FilePath (Join-Path $directory 'voicemeeter.exe') | Out-Null
            if ($null -ne $state.VbanEnable) { Start-Sleep -Seconds 3; $null = Invoke-Voicemeeter { param($r) Set-VoicemeeterVban $r ([float]$state.VbanEnable) } }
        }
    }
    Remove-Item -LiteralPath $statePath -Force
    foreach ($file in @($configPath, $exe)) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    Write-Output 'Drivers, device names, hidden outputs, default devices and startup entries were restored.'
    if ($result.Reboot) { Write-Warning 'Windows reports that a restart completes the driver change.' }
}

switch ($Action) {
    'Elevated' { Invoke-ElevatedPlan }
    'Setup' {
        try { Invoke-Setup }
        catch {
            # Keep audio flowing with the previous configuration if setup stops part way.
            if ((Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $exe) -and -not @(Get-SenderProcess).Count) {
                try { $null = Start-Sender; Write-Warning 'Setup failed; the previous sender configuration was restarted.' } catch { }
            }
            throw
        }
    }
    'Restore' { Invoke-Restore }
    'Start' { if (-not (Test-Path -LiteralPath $configPath)) { throw 'Run Setup first.' }; Stop-Sender; $null = Start-Sender; Write-Output 'Sender started.' }
    'Stop' { Stop-Sender; Write-Output 'Sender stopped (startup entry unchanged).' }
    'Status' {
        $running = @(Get-SenderProcess)
        Write-Output ('Sender running: ' + [bool]$running.Count)
        if (Test-Path -LiteralPath $configPath) { Write-Output ('Configuration: ' + ((Get-Content -LiteralPath $configPath) -join ' ')) }
        Write-Output ('Startup entry: ' + (Get-RunValue $senderRunName).Exists)
        $default = $endpoints::GetDefault(0)
        Write-Output ('Default output: ' + ($endpoints::ListRender() | Where-Object Id -eq $default | Select-Object -First 1).Name)
        $state = Read-State
        if ($state) { Write-Output ('Recorded changes: {0} driver(s), {1} renamed output(s), {2} hidden output(s)' -f @($state.Drivers).Count, @($state.Descriptions).Count, @($state.Hidden).Count) }
        if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 200 -Encoding UTF8 | Where-Object { $_ -match '"event":"(capture|error|default_endpoint)"' } | Select-Object -Last 3 }
    }
}
