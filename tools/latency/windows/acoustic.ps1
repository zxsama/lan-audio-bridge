# SPDX-License-Identifier: MIT
# Acoustic end-to-end latency through the installed sender:
#   marker -> Windows default output -> vban-sender -> NAS -> speaker -> microphone.
# Plays short noise bursts (default -8.7 dBFS, 21 ms) over a quiet -55 dBFS tone that keeps the NAS
# session steady; times each onset from the microphone's capture QPC timestamps (one clock).
# Example: tools/latency/windows/acoustic.ps1 -MicName BRIO -Count 40
param([string]$Mic, [string]$MicName, [int]$Count = 40, [int]$Period = 128, [int]$MaxFill = 160,
      [double]$K = 8, [int]$Pattern = 1024, [int]$Level = 12000, [string]$Output)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Add-Type -Path (Join-Path $root 'scripts\windows\AudioInterop.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'LatencyProbe.cs')
if (-not @(Get-Process vban-sender -ErrorAction SilentlyContinue).Count) { throw 'The installed sender is not running (Setup-Windows-Audio.cmd Start).' }
if (-not $Mic) {
    if ($MicName) {
        $Mic = (Get-PnpDevice -Class AudioEndpoint -PresentOnly | Where-Object { $_.FriendlyName -like "*$MicName*" -and $_.InstanceId -like 'SWD\MMDEVAPI\{0.0.1.*' } |
            Select-Object -First 1 | ForEach-Object { $_.InstanceId -replace '^SWD\\MMDEVAPI\\', '' })
        if (-not $Mic) { throw "No active microphone matches '$MicName'." }
    } else { $Mic = [LatencyProbe]::DefaultCaptureId() }
}
$render = [LanAudioBridge.WindowsAudio.Endpoints]::GetDefault(0)
Write-Host "Output: $render  Microphone: $Mic"
[LatencyProbe]::Count = $Count; [LatencyProbe]::MaxFill = $MaxFill; [LatencyProbe]::Background = 60 / 32768.0
[LatencyProbe]::PatternLength = $Pattern; [LatencyProbe]::Level = [int16]$Level
$a = [LatencyProbe]::RunAcoustic($render, $Mic.ToLowerInvariant(), [uint32]$Period, $K)
function P($d, $p) { $x = @($d | Sort-Object); if (-not $x.Count) { return $null }; [math]::Round($x[[math]::Max(0, [int][math]::Ceiling($p * $x.Count) - 1)], 2) }
$r = [ordered]@{ Time = (Get-Date).ToString('o'); Output = $render; Microphone = $Mic; Period = $Period; MaxFill = $MaxFill; Error = $a.Error
    Detected = $a.QpcDelays.Count; Markers = $Count
    QpcMs = [ordered]@{ Min = (P $a.QpcDelays 0.0001); Median = (P $a.QpcDelays 0.5); P95 = (P $a.QpcDelays 0.95); Max = (P $a.QpcDelays 1) }
    ArrivalMedianMs = (P $a.ArrivalDelays 0.5); SnrDbMin = (P $a.Snr 0.0001); Delays = @($a.QpcDelays | ForEach-Object { [math]::Round($_, 2) }) }
if ($Output) { $r | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Output -Encoding utf8 }
$r | ConvertTo-Json -Depth 4
