# Process policy tests. Default run is read-only; no running mixer is modified.
[CmdletBinding()]
param([switch]$ExerciseCurrentProcess)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $repo 'scripts\windows\AudioInterop.cs')
Import-Module (Join-Path $repo 'scripts\windows\Voicemeeter.psm1') -Force
$checks = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -ne $Expected) { throw ($Label + ': expected ' + $Expected + ', received ' + $Actual) }
    $script:checks++
}
function Assert-Fails([scriptblock]$Action, [string]$Message) {
    try { & $Action } catch {
        if ($_.Exception.ToString() -notmatch [regex]::Escape($Message)) { throw }
        $script:checks++
        return
    }
    throw ('Expected failure: ' + $Message)
}

# Pure transformation preserves unrelated flags and never changes the original snapshot.
$original = New-Object LanAudioBridge.WindowsAudio.ProcessPowerSnapshot
$original.ProcessId = 42
$original.ExecutablePath = 'C:\test\voicemeeter.exe'
$original.CreationTime = 123456789
$original.ControlMask = 9
$original.StateMask = 9
$timerOnly = [LanAudioBridge.WindowsAudio.ProcessRuntime]::DesiredPolicy($original, $false)
Assert-Equal $timerOnly.ControlMask 13 'Timer control added'
Assert-Equal $timerOnly.StateMask 9 'Execution and unrelated flags preserved'
$both = [LanAudioBridge.WindowsAudio.ProcessRuntime]::DesiredPolicy($original, $true)
Assert-Equal $both.ControlMask 13 'Both controls enabled'
Assert-Equal $both.StateMask 8 'Only requested throttling flags disabled'
Assert-Equal $original.StateMask 9 'Input snapshot unchanged'
Assert-Equal $both.CreationTime 123456789 'Process generation preserved'
$roundTrip = ConvertTo-ProcessPowerSnapshot ($both | ConvertTo-Json | ConvertFrom-Json)
Assert-Equal $roundTrip.CreationTime $both.CreationTime 'JSON identity roundtrip'
Assert-Equal $roundTrip.ControlMask $both.ControlMask 'JSON flags roundtrip'

# Real native reads verify ABI, native structure size and process-path validation.
$self = [Diagnostics.Process]::GetCurrentProcess()
$baseline = [LanAudioBridge.WindowsAudio.ProcessRuntime]::Get($self.Id, $self.MainModule.FileName)
Assert-Equal $baseline.ProcessId $self.Id 'Read current PID'
Assert-Equal $baseline.ExecutablePath $self.MainModule.FileName 'Read current executable'
Assert-Fails { [LanAudioBridge.WindowsAudio.ProcessRuntime]::Get($self.Id, 'C:\different\voicemeeter.exe') } 'does not match'
$stale = ConvertTo-ProcessPowerSnapshot $baseline
$stale.CreationTime++
Assert-Fails { [LanAudioBridge.WindowsAudio.ProcessRuntime]::Apply($stale, $false) } 'process restarted'
$conflict = ConvertTo-ProcessPowerSnapshot $baseline
$conflict.ControlMask = $conflict.ControlMask -bxor 4
Assert-Fails { [LanAudioBridge.WindowsAudio.ProcessRuntime]::Apply($conflict, $false) } 'changed since the snapshot'
$unchanged = [LanAudioBridge.WindowsAudio.ProcessRuntime]::Get($self.Id, $self.MainModule.FileName)
Assert-Equal $unchanged.ControlMask $baseline.ControlMask 'Rejected writes preserve control mask'
Assert-Equal $unchanged.StateMask $baseline.StateMask 'Rejected writes preserve state mask'

if ($ExerciseCurrentProcess) {
    # Explicit opt-in: mutate only this disposable test process, always restore it.
    $change = $null
    try {
        $change = [LanAudioBridge.WindowsAudio.ProcessRuntime]::Apply($baseline, $true)
        Assert-Equal ($change.After.ControlMask -band 5) 5 'Native control readback'
        Assert-Equal ($change.After.StateMask -band 5) 0 'Native disabled readback'
    } finally {
        if ($null -ne $change) {
            $restored = [LanAudioBridge.WindowsAudio.ProcessRuntime]::Restore($change)
            Assert-Equal $restored.ControlMask $baseline.ControlMask 'Native restored controls'
            Assert-Equal $restored.StateMask $baseline.StateMask 'Native restored state'
        }
    }
}
Write-Output ('Passed ' + $checks + ' runtime checks. Current-process mutation: ' + [bool]$ExerciseCurrentProcess)
