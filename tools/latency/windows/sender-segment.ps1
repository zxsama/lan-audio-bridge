# SPDX-License-Identifier: MIT
# Windows segment only: marker submit -> output endpoint -> vban-sender (WASAPI loopback) -> VBAN on 127.0.0.1.
# Temporarily stops the installed sender (single instance), runs a private one to localhost, then restarts it.
# -Period 128 models a low-latency (IAudioClient3) player; -Period 0 -BufferMs 10 a typical shared-mode player.
param([string]$Endpoint, [int]$Count = 40, [int]$Period = 128, [int]$MaxFill = 160, [int]$BufferMs = 10, [int]$Port = 16999)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
Add-Type -Path (Join-Path $root 'scripts\windows\AudioInterop.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'LatencyProbe.cs')
if (-not $Endpoint) { $Endpoint = [LanAudioBridge.WindowsAudio.Endpoints]::GetDefault(0) }
$installed = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LanAudioBridge\Sender\vban-sender.exe'
$exe = if (Test-Path -LiteralPath $installed) { $installed } else { Join-Path $root 'dist\windows\vban-sender.exe' }
$wasRunning = @(Get-Process vban-sender -ErrorAction SilentlyContinue).Count -gt 0
if ($wasRunning) { & (Join-Path $root 'scripts\windows-audio.ps1') -Action Stop | Out-Null }
$sender = Start-Process -FilePath $exe -ArgumentList @('--target', '127.0.0.1', '--port', [string]$Port, '--device', ('"' + $Endpoint + '"'),
    '--no-endpoint-volume', '--idle-ms', '0') -WindowStyle Hidden -PassThru
try {
    Start-Sleep -Milliseconds 1500
    [LatencyProbe]::Count = $Count; [LatencyProbe]::MaxFill = $MaxFill; [LatencyProbe]::Background = 60 / 32768.0
    $r = [LatencyProbe]::RunVban($Endpoint, [uint32]$Period, $BufferMs, $Port, 1200)
    $d = @($r.Marks | Where-Object { $_.DelayMs -gt 0 } | ForEach-Object { $_.DelayMs } | Sort-Object)
    [pscustomobject]@{ Endpoint = $Endpoint; Period = $Period; MaxFill = $MaxFill; RenderBuffer = $r.RenderBuffer; Detected = $d.Count
        Min = [math]::Round($d[0], 2); Median = [math]::Round($r.MedianMs, 2); P95 = [math]::Round($r.P95Ms, 2); Max = [math]::Round($r.MaxMs, 2); Error = $r.Error } | ConvertTo-Json
} finally {
    $null = Start-Process -FilePath $exe -ArgumentList '--stop' -WindowStyle Hidden -Wait -PassThru
    if (-not $sender.HasExited) { Stop-Process -Id $sender.Id -Force }
    if ($wasRunning) { & (Join-Path $root 'scripts\windows-audio.ps1') -Action Start | Out-Null }
}
