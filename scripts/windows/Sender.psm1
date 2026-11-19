# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
# SPDX-License-Identifier: MIT
# Pure helpers for the native low-latency sender (no system changes here).
Set-StrictMode -Version 2.0

# Names of virtual/routing endpoints that must never be captured: their loopback
# lags behind an internal driver buffer (measured 61-104 ms on Voicemeeter VAIO).
$script:ExcludedEndpointPattern = 'VB-Audio|Voicemeeter|VB-Cable|CABLE Input|Steam Streaming|Virtual Audio'

function ConvertFrom-SenderEndpointList {
    param([AllowEmptyCollection()][string[]]$Lines)
    $result = @()
    foreach ($line in $Lines) {
        if (-not $line -or -not $line.TrimStart().StartsWith('{')) { continue }
        $value = $line | ConvertFrom-Json
        foreach ($name in @('id', 'name', 'default', 'min_frames', 'default_frames')) {
            if (-not $value.PSObject.Properties[$name]) { throw "Sender endpoint list is missing '$name'." }
        }
        $result += $value
    }
    return ,$result
}

# Ranks capture candidates: physical/non-Bluetooth endpoints first by smallest
# shared-mode engine period, keeping enumeration order for ties.
function Select-SenderEndpoints {
    param([AllowEmptyCollection()][object[]]$Endpoints, [hashtable]$ParentDevices = @{}, [int]$Maximum = 3)
    $index = 0
    $ranked = foreach ($endpoint in $Endpoints) {
        $parent = if ($ParentDevices.ContainsKey([string]$endpoint.id)) { [string]$ParentDevices[[string]$endpoint.id] } else { '' }
        $excluded = ([string]$endpoint.name -match $script:ExcludedEndpointPattern) -or ($parent -match '^\{1\}\.BTH')
        if (-not $excluded -and [int]$endpoint.min_frames -gt 0) {
            [pscustomobject]@{ Endpoint = $endpoint; Order = $index }
        }
        $index++
    }
    return ,@(@($ranked | Sort-Object @{ Expression = { [int]$_.Endpoint.min_frames } }, Order |
        Select-Object -First $Maximum | ForEach-Object Endpoint))
}

# HDMI/DisplayPort audio functions disappear while the monitor sleeps.
function Test-DisplayAudioDevice {
    param([string]$ParentDevice)
    return [bool]($ParentDevice -match 'HDAUDIO\\FUNC_01&VEN_(10DE|1002)&' -or $ParentDevice -match 'HDAUDIO\\FUNC_01&VEN_8086&DEV_28')
}

# Primary = best ranked endpoint. When it is display audio, the backup is the best
# endpoint that stays present (a non-display device); otherwise the runner-up.
function Select-SenderPreference {
    param([AllowEmptyCollection()][object[]]$Endpoints, [hashtable]$ParentDevices = @{})
    $ranked = Select-SenderEndpoints $Endpoints $ParentDevices 64
    if (-not $ranked.Count) { return ,@() }
    $parent = { param($id) if ($ParentDevices.ContainsKey([string]$id)) { [string]$ParentDevices[[string]$id] } else { '' } }
    $primary = $ranked[0]
    $rest = @($ranked | Select-Object -Skip 1)
    $backup = if (Test-DisplayAudioDevice (& $parent $primary.id)) {
        $rest | Where-Object { -not (Test-DisplayAudioDevice (& $parent $_.id)) } | Select-Object -First 1
    } else { $rest | Select-Object -First 1 }
    return ,@(@($primary, $backup) | Where-Object { $_ } | ForEach-Object id)
}

# Devices whose vendor driver can be replaced by a Microsoft class driver that
# supports smaller shared-mode engine periods (measured: HDMI 480 -> 128 frames,
# USB Audio 2.0 480 -> 336 frames). Input: PnP records with InstanceId, Name,
# Status, Provider, Inf, HardwareIds, CompatibleIds.
function Get-DriverSwitchPlan {
    param([AllowEmptyCollection()][object[]]$Devices)
    $plan = foreach ($device in $Devices) {
        if ($device.Status -ne 'OK' -or [string]$device.Provider -eq 'Microsoft' -or -not @($device.HardwareIds).Count) { continue }
        $hardware = [string]@($device.HardwareIds)[0]
        $inbox = $null
        if ($hardware -match '^HDAUDIO\\FUNC_01&VEN_(10DE|1002)&' -or $hardware -match '^HDAUDIO\\FUNC_01&VEN_8086&DEV_28') { $inbox = 'hdaudio.inf' }
        elseif (@($device.CompatibleIds) -contains 'USB\Class_01&SubClass_00&Prot_20') { $inbox = 'usbaudio2.inf' }
        if ($inbox) {
            [pscustomobject]@{ InstanceId = [string]$device.InstanceId; Name = [string]$device.Name; HardwareId = $hardware
                InboxInf = $inbox; OriginalInf = [string]$device.Inf; OriginalProvider = [string]$device.Provider }
        }
    }
    return ,@($plan)
}

# Reads the preferred endpoints and their identities from an existing sender.conf.
function ConvertFrom-SenderConfig {
    param([AllowEmptyCollection()][string[]]$Lines)
    $entries = @()
    for ($i = 0; $i -lt $Lines.Count - 1; $i++) {
        $value = $Lines[$i + 1]
        switch ($Lines[$i]) {
            '--prefer' { $entries += [pscustomobject]@{ Id = $value; Parent = ''; Labels = @() } }
            '--match' { if ($entries.Count) { $entries[-1].Parent = $value } }
            '--label' { if ($entries.Count) { $entries[-1].Labels = @($entries[-1].Labels) + $value } }
        }
    }
    return ,$entries
}

# Maps previous preferences to current endpoint IDs. An entry whose ID is still
# active keeps it; otherwise a matching description (one of its labels) is
# required and the same parent device breaks ties. Ambiguous or missing matches
# are dropped instead of guessed. Same rule as vban-sender's rebinding.
function Resolve-SenderPreference {
    param([AllowEmptyCollection()][object[]]$Entries, [AllowEmptyCollection()][string[]]$Active,
          [hashtable]$Parents = @{}, [hashtable]$Descriptions = @{})
    $result = @()
    foreach ($entry in $Entries) {
        $taken = @($result | ForEach-Object Id)
        if ($Active -contains $entry.Id -and $taken -notcontains $entry.Id) {
            $result += [pscustomobject]@{ Id = $entry.Id; Previous = $entry.Id; Entry = $entry }; continue
        }
        $scored = foreach ($id in $Active) {
            if ($taken -contains $id) { continue }
            $desc = if ($Descriptions.ContainsKey($id)) { [string]$Descriptions[$id] } else { '' }
            if (-not $desc -or @($entry.Labels) -notcontains $desc) { continue }
            $parent = if ($Parents.ContainsKey($id)) { [string]$Parents[$id] } else { '' }
            [pscustomobject]@{ Id = $id; Score = 1 + $(if ($entry.Parent -and $parent -eq $entry.Parent) { 2 } else { 0 }) }
        }
        $scored = @($scored | Sort-Object Score -Descending)
        if ($scored.Count -and ($scored.Count -eq 1 -or $scored[0].Score -gt $scored[1].Score)) {
            $result += [pscustomobject]@{ Id = $scored[0].Id; Previous = $entry.Id; Entry = $entry }
        }
    }
    return ,$result
}

function Assert-SenderEndpointId {
    param([string]$Id)
    if (-not $Id -or $Id.Length -ge 256 -or $Id -match '[\r\n\x00]') { throw 'Invalid playback endpoint ID.' }
}

function New-SenderConfigLines {
    param([string]$Address, [int]$Port = 6980, [string]$StreamName = 'Windows',
          [AllowEmptyCollection()][string[]]$Prefer = @(), [string]$LogPath, [hashtable]$Identity = @{})
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or $Address -ne $ip.ToString()) {
        throw 'Address must be the NAS IPv4 address, for example 192.168.1.20.'
    }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port must be in 1..65535.' }
    $bytes = [Text.Encoding]::UTF8.GetByteCount($StreamName)
    if ($bytes -lt 1 -or $bytes -gt 16 -or $StreamName -match '[\x00-\x1f]') { throw 'StreamName must be 1..16 UTF-8 bytes without control characters.' }
    if ($Prefer.Count -gt 8) { throw 'At most 8 preferred endpoints are supported.' }
    # --idle-ms 0: keep sending silence so the NAS output stays connected and awake.
    $lines = @('--target', $Address, '--port', [string]$Port, '--stream', $StreamName, '--stats-ms', '60000', '--idle-ms', '0')
    foreach ($id in $Prefer) {
        Assert-SenderEndpointId $id
        $lines += @('--prefer', $id)
        # Identity lets the sender find the endpoint again if Windows gives it a new ID.
        if ($Identity.ContainsKey($id)) {
            $parent = [string]$Identity[$id].Parent
            if ($parent -and $parent -notmatch '[\r\n]') { $lines += @('--match', $parent) }
            foreach ($label in @($Identity[$id].Labels | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 3)) {
                if ($label -notmatch '[\r\n]') { $lines += @('--label', [string]$label) }
            }
        }
    }
    if ($LogPath) {
        if ($LogPath -match '[\r\n]') { throw 'Invalid log path.' }
        $lines += @('--log', $LogPath)
    }
    return ,$lines
}

function New-SenderRunCommand {
    param([string]$Executable, [string]$ConfigPath)
    foreach ($path in @($Executable, $ConfigPath)) {
        if (-not $path -or $path.Contains('"')) { throw 'Invalid sender path.' }
    }
    $command = '"' + $Executable + '" --config "' + $ConfigPath + '"'
    # Windows ignores longer Run entries.
    if ($command.Length -gt 260) { throw 'The local user profile path is too long for a Windows Run startup entry.' }
    return $command
}

Export-ModuleMember -Function ConvertFrom-SenderEndpointList, Select-SenderEndpoints, Select-SenderPreference,
    ConvertFrom-SenderConfig, Resolve-SenderPreference,
    Test-DisplayAudioDevice, Get-DriverSwitchPlan, Assert-SenderEndpointId,
    New-SenderConfigLines, New-SenderRunCommand
