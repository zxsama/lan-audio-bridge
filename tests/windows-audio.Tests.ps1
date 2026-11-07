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
$parents = @{ dell = '{1}.HDAUDIO\FUNC_01&VEN_10DE&DEV_009A&SUBSYS_1462389B&REV_1001\5&2BA01E5D&0&0001'
             phl = '{1}.HDAUDIO\FUNC_01&VEN_10DE&DEV_009A&SUBSYS_1462389B&REV_1001\5&2BA01E5D&0&0002'
             spdif = '{1}.USB\VID_0DB0&PID_D6E7&MI_00\9&CC90BB9&0&0000'; bt = '{1}.BTHENUM\{0000110B}' }
Assert-True (Test-DisplayAudioDevice $parents.dell) 'NVIDIA HDMI is display audio'
Assert-True (-not (Test-DisplayAudioDevice $parents.spdif)) 'USB audio is not display audio'
Assert-True (Test-DisplayAudioDevice '{1}.HDAUDIO\FUNC_01&VEN_8086&DEV_2812&SUBSYS_80860101') 'Intel display audio'
Assert-True (-not (Test-DisplayAudioDevice '{1}.HDAUDIO\FUNC_01&VEN_10EC&DEV_1168')) 'Realtek codec is not display audio'
Assert-True ((Select-SenderPreference $list $parents) -join ',' -eq 'dell,spdif') 'Display primary gets a persistent non-display backup'
$noDisplay = ConvertFrom-SenderEndpointList @('{"id":"a","name":"A","default":false,"min_frames":336,"default_frames":480}', '{"id":"b","name":"B","default":false,"min_frames":480,"default_frames":480}')
Assert-True ((Select-SenderPreference $noDisplay @{}) -join ',' -eq 'a,b') 'Non-display primary uses the runner-up'
Assert-True ((Select-SenderPreference @() @{}).Count -eq 0) 'No candidates, no preference'

$devices = @(
    [pscustomobject]@{ InstanceId = 'HDAUDIO\FUNC_01&VEN_10DE&DEV_009A\1'; Name = 'NVIDIA High Definition Audio'; Status = 'OK'; Provider = 'NVIDIA Corporation'; Inf = 'oem491.inf'
        HardwareIds = @('HDAUDIO\FUNC_01&VEN_10DE&DEV_009A&SUBSYS_1462389B&REV_1001'); CompatibleIds = @('HDAUDIO\FUNC_01') },
    [pscustomobject]@{ InstanceId = 'USB\VID_0DB0&PID_D6E7&MI_00\9'; Name = 'Realtek USB Audio'; Status = 'OK'; Provider = 'Realtek Semiconductor Corp.'; Inf = 'oem45.inf'
        HardwareIds = @('USB\VID_0DB0&PID_D6E7&REV_0002&MI_00'); CompatibleIds = @('USB\Class_01&SubClass_00&Prot_20', 'USB\Class_01') },
    [pscustomobject]@{ InstanceId = 'HDAUDIO\FUNC_01&VEN_10EC&DEV_1168\1'; Name = 'Realtek HD Audio'; Status = 'OK'; Provider = 'Realtek'; Inf = 'oem9.inf'
        HardwareIds = @('HDAUDIO\FUNC_01&VEN_10EC&DEV_1168'); CompatibleIds = @('HDAUDIO\FUNC_01') },
    [pscustomobject]@{ InstanceId = 'HDAUDIO\FUNC_01&VEN_10DE&DEV_009A\2'; Name = 'Already inbox'; Status = 'OK'; Provider = 'Microsoft'; Inf = 'hdaudio.inf'
        HardwareIds = @('HDAUDIO\FUNC_01&VEN_10DE&DEV_009A&SUBSYS_1'); CompatibleIds = @() },
    [pscustomobject]@{ InstanceId = 'USB\VID_1\1'; Name = 'Absent'; Status = 'Unknown'; Provider = 'Vendor'; Inf = 'oem1.inf'
        HardwareIds = @('USB\VID_1'); CompatibleIds = @('USB\Class_01&SubClass_00&Prot_20') })
$plan = Get-DriverSwitchPlan $devices
Assert-True ($plan.Count -eq 2) 'Only vendor-driven display audio and USB Audio 2.0 devices are switched'
Assert-True ($plan[0].InboxInf -eq 'hdaudio.inf' -and $plan[0].OriginalInf -eq 'oem491.inf' -and $plan[0].HardwareId -like 'HDAUDIO*SUBSYS_1462389B*') 'HDMI uses hdaudio.inf and records the vendor package'
Assert-True ($plan[1].InboxInf -eq 'usbaudio2.inf' -and $plan[1].OriginalInf -eq 'oem45.inf') 'USB Audio 2.0 uses usbaudio2.inf'
Assert-True ((Get-DriverSwitchPlan @()).Count -eq 0) 'Empty device list'

$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows-audio.ps1'), [ref]$tokens, [ref]$errors)
Assert-True (-not $errors.Count) ('Setup script parses: ' + ($errors -join '; '))
$bytes = [IO.File]::ReadAllBytes((Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows-audio.ps1'))
Assert-True (-not ($bytes | Where-Object { $_ -gt 127 })) 'Setup script stays ASCII for Windows PowerShell 5.1'
Write-Output "windows-audio checks passed: $script:checks"
