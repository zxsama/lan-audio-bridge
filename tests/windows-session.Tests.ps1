# Isolated launcher orchestration tests; no native APIs, registry or real processes.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\windows-audio.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
# Load only reviewed function definitions, never execute the launcher entry point.
foreach ($name in @('Save-OriginalMixerState', 'Update-NativePlaybackOptions', 'Enable-BackgroundPlayback', 'Restore-BackgroundPlayback',
    'Test-DriverVolumeEnabled', 'Ensure-DriverVolumeControl', 'Restore-DriverVolumeControl')) {
    $node = $ast.Find({ param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name }, $false)
    if (-not $node) { throw ('Missing function ' + $name) }
    . ([scriptblock]::Create($node.Extent.Text))
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('lan-audio-session-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$script:results = New-Object 'Collections.Generic.List[object]'
$directory = Join-Path $scratch 'application'
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw ('Expected [' + $Expected + '], got [' + $Actual + '].') }
}
function Assert-True($Value) { if (-not $Value) { throw 'Assertion failed.' } }
function Assert-Fails([scriptblock]$Body, [string]$Message) {
    try { & $Body } catch { if ($_.Exception.ToString() -notmatch [regex]::Escape($Message)) { throw }; return }
    throw ('Expected failure: ' + $Message)
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    Reset-Fixture
    try { & $Body; $script:results.Add([pscustomobject]@{Name=$Name;Passed=$true}); Write-Host ('PASS ' + $Name) }
    catch { $script:results.Add([pscustomobject]@{Name=$Name;Passed=$false}); Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function New-FakeRemote([string]$Name) {
    $value = [pscustomobject]@{ Name=$Name }
    $value | Add-Member ScriptMethod SetFloat { param($key,$number) $script:events.Add($this.Name + ':' + $key) }
    $value | Add-Member ScriptMethod Dispose { $script:events.Add($this.Name + ':dispose') }
    return $value
}
function Reset-Fixture {
    $script:stateRoot = Join-Path $scratch ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stateRoot | Out-Null
    $script:events = New-Object 'Collections.Generic.List[string]'
    $script:tray = [pscustomobject]@{Enabled=$false;Value='tray-before'}
    $script:engine = [pscustomobject]@{Enabled=$false;Value='engine-before'}
    $script:waitSuccess = $true; $script:running = $true
    $script:failSave = $false; $script:failEngine = $false; $script:failLoad = $false; $script:failJson = $false
    $script:failConnectCount = 0; $script:connectCount = 0
    $script:loadedExpected = $null; $script:loadedProfile = $null
    $script:policy = [pscustomobject]@{ProcessId=42;CreationTime=123;ControlMask=1;StateMask=1}
    $script:driver = [pscustomobject]@{RuntimeEnabled=$false;Registry=@([pscustomobject]@{Exists=$false;Kind=$null;Value=$null})}
    $script:helperFixesState = $true
    $script:old = New-FakeRemote 'old'
    $script:new = New-FakeRemote 'new'
    $script:mixer = [pscustomobject]@{Path=(Join-Path $directory 'voicemeeter.exe');Id=42}
    $script:mixer | Add-Member ScriptMethod WaitForExit {
        param($timeout)
        $script:events.Add('wait')
        if ($script:waitSuccess) { $script:running=$false }
        return $script:waitSuccess
    }
}
function Get-Process { param($Name,$ErrorAction) if ($script:running) { return $script:mixer } }
function Get-VoicemeeterTrayState { param($VoicemeeterPath) return $script:tray }
function Get-VoicemeeterEngineState { param($VoicemeeterPath) return $script:engine }
function Save-VoicemeeterXml { param($Connection,$Path) $script:events.Add('save'); if ($script:failSave) {throw 'save failed'}; [IO.File]::WriteAllText($Path,'<Voicemeeter/>') }
function Get-DesktopAudioSnapshot {
    param($Connection,$Config,$Slot)
    $script:events.Add('snapshot:' + $Slot)
    return [ordered]@{("vban.outstream[$Slot].route")=$Slot;("vban.outstream[$Slot].on")=0;'Bus[1].Gain'=-3.5}
}
function Write-AudioJson { param($Path,$Value) if ($script:failJson) {throw 'json failed'}; [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 8)) }
function Set-VoicemeeterTrayMode { param($Path,$BackupPath) $script:events.Add('tray:set'); $script:tray | Export-Clixml -LiteralPath $BackupPath; $script:tray=[pscustomobject]@{Enabled=$true;Value='tray-managed'} }
function Set-VoicemeeterEngineLatency {
    param($Path,$BackupPath)
    $script:events.Add('engine:set')
    if ($script:failEngine) {throw 'engine failed'}
    $script:engine | Export-Clixml -LiteralPath $BackupPath
    $script:engine=[pscustomobject]@{Enabled=$true;Value='engine-managed'}
}
function Restore-VoicemeeterTrayState { param($Path,$Snapshot) $script:events.Add('tray:restore'); $script:tray=$Snapshot }
function Restore-VoicemeeterEngineState { param($Path,$Snapshot) $script:events.Add('engine:restore'); $script:engine=$Snapshot }
function Connect-Remote {
    param($Directory,[switch]$StartIfNeeded,$ProfilePath)
    $script:events.Add('connect'); $script:connectCount++
    if ($script:connectCount -le $script:failConnectCount) { throw 'connect failed' }
    $script:running=$true; $script:loadedProfile=$ProfilePath
    return $script:new
}
function Restore-VoicemeeterXml {
    param($Connection,$Path,$Expected)
    $script:events.Add('load'); $script:loadedExpected=$Expected
    if ($script:failLoad) { throw 'load failed' }
}
function Get-VoicemeeterRuntimePowerPolicy { param($ProcessId,$Directory) return $script:policy }
function Set-VoicemeeterRuntimePowerPolicy { param($Snapshot,$BackupPath) $script:events.Add('power:set'); [IO.File]::WriteAllText($BackupPath,'fake') }
function Restore-VoicemeeterRuntimePowerPolicy { param($BackupPath) $script:events.Add('power:restore:' + [IO.Path]::GetFileName($BackupPath)) }
function Get-DriverVolumeControlState { param($ControlPanelPath) return $script:driver }
function Invoke-DriverVolumeAction {
    param($DriverAction)
    $script:events.Add('driver:' + $DriverAction)
    if (-not $script:helperFixesState) { return }
    if ($DriverAction -eq 'Enable') { $script:driver=[pscustomobject]@{RuntimeEnabled=$true;Registry=@([pscustomobject]@{Exists=$true;Kind='DWord';Value=1})} }
    else { $script:driver=Get-Content -LiteralPath (Join-Path $stateRoot 'driver-volume-original.json') -Raw | ConvertFrom-Json }
}
function Save-PolicyRecord([string]$Status,$Before,$After) {
    $path=Join-Path $stateRoot ('runtime-power-' + $policy.ProcessId + '-' + $policy.CreationTime + '.json')
    Write-AudioJson $path ([pscustomobject]@{Schema=1;Status=$Status;Before=$Before;After=$After})
    return $path
}

try {
    Test-Case 'Original mixer backup includes all four streams and preserves the first complete snapshot' {
        Save-OriginalMixerState $old @{}
        $saved=Get-Content -LiteralPath (Join-Path $stateRoot 'original-parameters.json') -Raw | ConvertFrom-Json
        Assert-Equal $saved.'vban.outstream[3].route' 3
        Assert-Equal $saved.'Bus[1].Gain' -3.5
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'original.xml'))
        Save-OriginalMixerState $old @{}
        Assert-Equal ($events -join ',') 'save,snapshot:0,snapshot:1,snapshot:2,snapshot:3'
    }
    Test-Case 'Failed original parameter backup does not suppress a complete retry' {
        $script:failJson=$true
        Assert-Fails {Save-OriginalMixerState $old @{}} 'json failed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'original.xml')))
        $script:failJson=$false
        Save-OriginalMixerState $old @{}
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'original.xml'))
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'original-parameters.json'))
    }
    Test-Case 'Native options preserve all four output slots before exactly one restart' {
        $result=Update-NativePlaybackOptions $old $directory @{}
        Assert-True ([object]::ReferenceEquals($result,$new))
        Assert-Equal ($events -join ',') 'save,snapshot:0,snapshot:1,snapshot:2,snapshot:3,old:Command.Shutdown,wait,old:dispose,tray:set,engine:set,connect,load'
        Assert-Equal $loadedExpected.Count 9
        Assert-Equal $loadedExpected['vban.outstream[3].route'] 3
        Assert-True (Test-Path -LiteralPath ($loadedProfile + '.json'))
    }
    Test-Case 'Already enabled native preferences preserve the existing mixer connection' {
        $tray.Enabled=$true; $engine.Enabled=$true
        $result=Update-NativePlaybackOptions $old $directory @{}
        Assert-True ([object]::ReferenceEquals($result,$old)); Assert-Equal $events.Count 0
    }
    Test-Case 'Restore with no native backup does not restart' {
        $null=Update-NativePlaybackOptions $old $directory @{} -Restore
        Assert-Equal $events.Count 0
    }
    Test-Case 'Save failure precedes every process or preference change' {
        $script:failSave=$true
        Assert-Fails {Update-NativePlaybackOptions $old $directory @{}} 'save failed'
        Assert-Equal ($events -join ',') 'save'
    }
    Test-Case 'Shutdown timeout leaves preferences untouched and connection undisposed' {
        $script:waitSuccess=$false
        Assert-Fails {Update-NativePlaybackOptions $old $directory @{}} 'did not stop'
        Assert-True (-not ($events -contains 'old:dispose')); Assert-True (-not ($events -contains 'tray:set'))
    }
    Test-Case 'Engine write failure recovers both original preferences and session' {
        $script:failEngine=$true
        Assert-Fails {Update-NativePlaybackOptions $old $directory @{}} 'engine failed'
        Assert-Equal $tray.Value 'tray-before'; Assert-Equal $engine.Value 'engine-before'
        Assert-Equal $connectCount 1; Assert-True ($events -contains 'load'); Assert-True ($events -contains 'new:dispose')
    }
    Test-Case 'First startup failure restores preferences and retries original session once' {
        $script:failConnectCount=1
        Assert-Fails {Update-NativePlaybackOptions $old $directory @{}} 'connect failed'
        Assert-Equal $connectCount 2; Assert-Equal $tray.Value 'tray-before'; Assert-Equal $engine.Value 'engine-before'
        Assert-True ($events -contains 'load')
    }
    Test-Case 'Recovery startup failure remains failure and retains profile and snapshots' {
        $script:failConnectCount=2
        Assert-Fails {Update-NativePlaybackOptions $old $directory @{} -WarningAction SilentlyContinue} 'connect failed'
        Assert-Equal $connectCount 2
        Assert-Equal @(Get-ChildItem -LiteralPath $stateRoot -Filter 'native-restart-*.xml').Count 1
        Assert-Equal @(Get-ChildItem -LiteralPath $stateRoot -Filter 'native-restart-*.xml.json').Count 1
    }
    Test-Case 'Load verification failure does not terminate a newly running mixer' {
        $script:failLoad=$true
        Assert-Fails {Update-NativePlaybackOptions $old $directory @{}} 'load failed'
        Assert-Equal $connectCount 1; Assert-True $running
        Assert-True (-not ($events -contains 'new:Command.Shutdown')); Assert-True ($events -contains 'new:dispose')
    }
    Test-Case 'Native Restore reads original values and performs one session-preserving restart' {
        [pscustomobject]@{Enabled=$false;Value='original-tray'} | Export-Clixml -LiteralPath (Join-Path $stateRoot 'tray-original.clixml')
        [pscustomobject]@{Enabled=$false;Value='original-engine'} | Export-Clixml -LiteralPath (Join-Path $stateRoot 'engine-original.clixml')
        $null=Update-NativePlaybackOptions $old $directory @{} -Restore
        Assert-Equal $tray.Value 'original-tray'; Assert-Equal $engine.Value 'original-engine'; Assert-Equal $connectCount 1
        Assert-True (-not ($events -contains 'tray:set')); Assert-Equal $loadedExpected.Count 9
    }
    Test-Case 'Background policy requires exactly one matching mixer' {
        $script:running=$false
        Assert-Fails {Enable-BackgroundPlayback $directory} 'exactly one'
        Assert-Equal $events.Count 0
    }
    Test-Case 'Background policy applies using the current process generation' {
        $result=Enable-BackgroundPlayback $directory
        Assert-True $result.Changed; Assert-Equal ([IO.Path]::GetFileName($result.Path)) 'runtime-power-42-123.json'
        Assert-Equal ($events -join ',') 'power:set'
    }
    Test-Case 'Login retry keeps an already applied timer policy without rewriting its backup' {
        $path=Save-PolicyRecord 'Applied' $policy $policy
        $before=[IO.File]::ReadAllText($path)
        $result=Enable-BackgroundPlayback $directory
        Assert-True (-not $result.Changed); Assert-Equal $events.Count 0; Assert-Equal ([IO.File]::ReadAllText($path)) $before
    }
    Test-Case 'Conflicting process policy is refused without any mutation' {
        $different=[pscustomobject]@{ControlMask=5;StateMask=0}
        $null=Save-PolicyRecord 'Applied' $policy $different
        Assert-Fails {Enable-BackgroundPlayback $directory} 'differs'
        Assert-Equal $events.Count 0
    }
    Test-Case 'Restored policy can be reapplied while retaining the previous backup' {
        $path=Save-PolicyRecord 'Restored' $policy $policy
        $result=Enable-BackgroundPlayback $directory
        Assert-True $result.Changed
        Assert-Equal @(Get-ChildItem -LiteralPath $stateRoot -Filter 'runtime-power-42-123.json.restored-*').Count 1
        Assert-Equal ($events -join ',') 'power:set'
    }
    Test-Case 'Restore selects only the current generation and ignores stale PID backups' {
        [IO.File]::WriteAllText((Join-Path $stateRoot 'runtime-power-42-122.json'),'stale')
        $null=Save-PolicyRecord 'Applied' $policy $policy
        Restore-BackgroundPlayback $directory
        Assert-Equal ($events -join ',') 'power:restore:runtime-power-42-123.json'
    }
    Test-Case 'Driver startup check is read-only and never elevates' {
        Assert-Fails {Ensure-DriverVolumeControl $directory -ReadOnly} 'startup does not request'
        Assert-Equal $events.Count 0; Assert-Equal @(Get-ChildItem -LiteralPath $stateRoot).Count 0
    }
    Test-Case 'Driver setup preserves first snapshot across idempotent retries' {
        Ensure-DriverVolumeControl $directory
        $path=Join-Path $stateRoot 'driver-volume-original.json'; $first=[IO.File]::ReadAllText($path)
        Ensure-DriverVolumeControl $directory
        Assert-Equal ([IO.File]::ReadAllText($path)) $first; Assert-Equal ($events -join ',') 'driver:Enable'
        Assert-True (-not ((ConvertFrom-Json $first).RuntimeEnabled))
    }
    Test-Case 'Driver helper success cannot bypass independent runtime readback' {
        $script:helperFixesState=$false
        Assert-Fails {Ensure-DriverVolumeControl $directory} 'independent readback'
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'driver-volume-original.json'))
    }
    Test-Case 'Driver Restore recovers original runtime and registry absence' {
        Ensure-DriverVolumeControl $directory
        Restore-DriverVolumeControl $directory
        Assert-True (-not $driver.RuntimeEnabled); Assert-True (-not $driver.Registry[0].Exists)
        Assert-Equal ($events -join ',') 'driver:Enable,driver:Restore'
    }
    Test-Case 'Driver Restore already matching original state does not elevate' {
        Write-AudioJson (Join-Path $stateRoot 'driver-volume-original.json') $driver
        Restore-DriverVolumeControl $directory
        Assert-Equal $events.Count 0
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
$failed=@($results | Where-Object {-not $_.Passed})
Write-Host ('Session orchestration: ' + ($results.Count - $failed.Count) + ' passed, ' + $failed.Count + ' failed.')
if ($failed.Count) { exit 1 }
