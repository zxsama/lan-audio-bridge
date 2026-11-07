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

function Assert-SenderEndpointId {
    param([string]$Id)
    if (-not $Id -or $Id.Length -ge 256 -or $Id -match '[\r\n\x00]') { throw 'Invalid playback endpoint ID.' }
}

function New-SenderConfigLines {
    param([string]$Address, [int]$Port = 6980, [string]$StreamName = 'Windows',
          [AllowEmptyCollection()][string[]]$Prefer = @(), [string]$LogPath)
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$ip) -or $ip.AddressFamily -ne 'InterNetwork' -or $Address -ne $ip.ToString()) {
        throw 'Address must be the NAS IPv4 address, for example 192.168.1.20.'
    }
    if ($Port -lt 1 -or $Port -gt 65535) { throw 'Port must be in 1..65535.' }
    $bytes = [Text.Encoding]::UTF8.GetByteCount($StreamName)
    if ($bytes -lt 1 -or $bytes -gt 16 -or $StreamName -match '[\x00-\x1f]') { throw 'StreamName must be 1..16 UTF-8 bytes without control characters.' }
    if ($Prefer.Count -gt 8) { throw 'At most 8 preferred endpoints are supported.' }
    $lines = @('--target', $Address, '--port', [string]$Port, '--stream', $StreamName, '--stats-ms', '60000')
    foreach ($id in $Prefer) { Assert-SenderEndpointId $id; $lines += @('--prefer', $id) }
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

Export-ModuleMember -Function ConvertFrom-SenderEndpointList, Select-SenderEndpoints, Assert-SenderEndpointId,
    New-SenderConfigLines, New-SenderRunCommand
