# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
# Pure sender helpers only; does not change the running installation.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\Sender.psm1') -Force
$script:checks = 0
function Assert-True($value, $message) { if (-not $value) { throw $message }; $script:checks++ }
function Assert-Fails([scriptblock]$action, $message) {
    try { & $action } catch {
        if ($_.Exception.Message -notmatch [regex]::Escape($message)) { throw }
        $script:checks++; return
    }
    throw ('Expected failure: ' + $message)
}

$lines = @(
    'noise before json',
    '{"id":"vaio","name":"Voicemeeter Input (VB-Audio Voicemeeter VAIO)","default":true,"min_frames":128,"default_frames":480}',
    '{"id":"spdif","name":"SPDIF (Realtek USB2.0 Audio)","default":false,"min_frames":336,"default_frames":480}',
    '{"id":"dell","name":"DELL U2722DX (High Definition Audio Device)","default":false,"min_frames":128,"default_frames":480}',
    '{"id":"bt","name":"Headphones (WH-1000XM6)","default":false,"min_frames":480,"default_frames":480}',
    '{"id":"steam","name":"Speakers (Steam Streaming Speakers)","default":false,"min_frames":480,"default_frames":480}',
    '{"id":"phl","name":"PHL 275M1RZ (High Definition Audio Device)","default":false,"min_frames":128,"default_frames":480}'
)
$list = ConvertFrom-SenderEndpointList $lines
Assert-True ($list.Count -eq 6) 'Endpoint list parses JSON lines only'
Assert-Fails { ConvertFrom-SenderEndpointList @('{"id":"x","name":"y"}') } "missing 'default'"

$ranked = Select-SenderEndpoints $list @{ bt = '{1}.BTHENUM\{0000110B}'; dell = '{1}.HDAUDIO\FUNC_01' }
Assert-True (($ranked | ForEach-Object id) -join ',' -eq 'dell,phl,spdif') 'Virtual and Bluetooth excluded; smallest period first; ties keep order'
Assert-True ((Select-SenderEndpoints $list @{} 1).Count -eq 1) 'Maximum candidate count respected'
Assert-True ((Select-SenderEndpoints @() @{}).Count -eq 0) 'Empty list yields no candidates'

$config = New-SenderConfigLines '192.168.50.77' 6980 'Windows' @('dell', 'spdif') 'C:\Users\a\sender.log'
Assert-True (($config -join '|') -eq '--target|192.168.50.77|--port|6980|--stream|Windows|--stats-ms|60000|--prefer|dell|--prefer|spdif|--log|C:\Users\a\sender.log') 'Config is one argument per line'
Assert-True ((New-SenderConfigLines '10.0.0.2').Count -eq 8) 'Config without preferences or log'
foreach ($bad in @('192.168.50', '192.168.050.1', '::1', 'nas.local', '')) {
    Assert-Fails { New-SenderConfigLines $bad } 'Address must be the NAS IPv4 address'
}
Assert-Fails { New-SenderConfigLines '10.0.0.2' 0 } 'Port must be'
Assert-Fails { New-SenderConfigLines '10.0.0.2' 6980 '12345678901234567' } 'StreamName must be'
Assert-Fails { New-SenderConfigLines '10.0.0.2' 6980 "a`nb" } 'StreamName must be'
Assert-Fails { New-SenderConfigLines '10.0.0.2' 6980 'Windows' @("x`ny") } 'Invalid playback endpoint ID'
Assert-Fails { New-SenderConfigLines '10.0.0.2' 6980 'Windows' @(1..9 | ForEach-Object { "e$_" }) } 'At most 8'

$command = New-SenderRunCommand 'C:\Users\a\AppData\Local\LanAudioBridge\Sender\vban-sender.exe' 'C:\Users\a\AppData\Local\LanAudioBridge\Sender\sender.conf'
Assert-True ($command -eq '"C:\Users\a\AppData\Local\LanAudioBridge\Sender\vban-sender.exe" --config "C:\Users\a\AppData\Local\LanAudioBridge\Sender\sender.conf"') 'Run command quotes both paths'
Assert-Fails { New-SenderRunCommand ('C:\' + ('x' * 250) + '.exe') 'C:\c.conf' } 'too long'
Assert-Fails { New-SenderRunCommand 'C:\a"b.exe' 'C:\c.conf' } 'Invalid sender path'
Write-Output "windows-sender checks passed: $script:checks"
