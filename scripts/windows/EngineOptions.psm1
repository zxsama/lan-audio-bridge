# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
Set-StrictMode -Version 2.0

# Verified Standard 1.1.3.0: VAIOLatency6 is the ordinary VAIO / B1 pair.
# The native engine reads this DWORD on startup and applies IOCTL 0x22204c.
# 3072 accommodates the existing MME 1024 and WDM 512 buffers (3x rule).
# ClockPreferredLatency and the other seven VAIO pairs are intentionally absent.
$script:EngineKey = 'VB-Audio\VoiceMeeter'
$script:EngineValue = 'VAIOLatency6'
$script:EngineLatency = 3072
$script:EngineHash = 'FC3ADB5F805F5294168CFE91193C501318395629400C0A4C38F7AB2427C6063A'
$script:TrayModule = Import-Module (Join-Path $PSScriptRoot 'TrayOptions.psm1') -PassThru -ErrorAction Stop

function Assert-EngineImage {
    param([string]$VoicemeeterPath)
    & $script:TrayModule { param($path) Assert-TrayImage $path } $VoicemeeterPath
}

function Assert-EngineStopped {
    & $script:TrayModule { Assert-TrayStopped }
}

function Get-EngineUserSid {
    & $script:TrayModule { Get-TrayUserSid }
}

function Read-EngineValue {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry32')
    $key = $null
    try {
        $key = $base.OpenSubKey($script:EngineKey, $false)
        if (-not $key) { throw 'Expected Voicemeeter configuration key is missing.' }
        $exists = $key.GetValueNames() -contains $script:EngineValue
        $kind = $null
        $value = $null
        if ($exists) {
            $kind = $key.GetValueKind($script:EngineValue).ToString()
            $value = $key.GetValue($script:EngineValue, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        [pscustomobject]@{ Exists = $exists; Kind = $kind; Value = $value }
    } finally {
        if ($key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Write-EngineValue {
    param($Snapshot)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry32')
    $key = $null
    try {
        $key = $base.OpenSubKey($script:EngineKey, $true)
        if (-not $key) { throw 'Expected Voicemeeter configuration key is missing.' }
        if ($Snapshot.Exists) {
            $key.SetValue($script:EngineValue, [int]$Snapshot.Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        } else {
            $key.DeleteValue($script:EngineValue, $false)
        }
    } finally {
        if ($key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Assert-EngineSnapshot {
    param($Snapshot)
    if ($Snapshot.Schema -ne 1 -or $Snapshot.ImageHash -cne $script:EngineHash -or
        $Snapshot.UserSid -cne (Get-EngineUserSid) -or $Snapshot.Key -cne $script:EngineKey -or
        $Snapshot.Name -cne $script:EngineValue -or $Snapshot.Exists -isnot [bool]) {
        throw 'Invalid native engine snapshot.'
    }
    if ($Snapshot.Exists) {
        if ($Snapshot.Kind -cne 'DWord' -or $Snapshot.Value -isnot [int] -or
            $Snapshot.Value -lt 384 -or $Snapshot.Value -gt 16384) {
            throw 'Unsupported existing VAIO latency layout; expected DWORD 384 through 16384.'
        }
    } elseif ($null -ne $Snapshot.Kind -or $null -ne $Snapshot.Value) {
        throw 'Invalid absent VAIO latency value.'
    }
}

function Test-EngineValueEqual {
    param($Left, $Right)
    return ($Left.Exists -eq $Right.Exists -and $Left.Kind -ceq $Right.Kind -and $Left.Value -ceq $Right.Value)
}

function Test-EngineManagedValue {
    param($State)
    return ($State.Exists -and $State.Kind -ceq 'DWord' -and $State.Value -eq $script:EngineLatency)
}

function Get-VoicemeeterEngineState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VoicemeeterPath)
    Assert-EngineImage $VoicemeeterPath
    $row = Read-EngineValue
    $state = [pscustomobject]@{
        Schema = 1
        ImageHash = $script:EngineHash
        UserSid = Get-EngineUserSid
        Key = $script:EngineKey
        Name = $script:EngineValue
        Exists = $row.Exists
        Kind = $row.Kind
        Value = $row.Value
        Enabled = Test-EngineManagedValue $row
        Optimized = Test-EngineManagedValue $row
    }
    Assert-EngineSnapshot $state
    return $state
}

function Restore-VoicemeeterEngineState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VoicemeeterPath, [Parameter(Mandatory)]$Snapshot)
    Assert-EngineSnapshot $Snapshot
    $current = Get-VoicemeeterEngineState $VoicemeeterPath
    Assert-EngineStopped
    if (Test-EngineValueEqual $current $Snapshot) { return $current }
    if (-not (Test-EngineManagedValue $current)) {
        throw 'VAIO latency changed outside this task; refusing to overwrite the conflicting value.'
    }
    Write-EngineValue $Snapshot
    $after = Get-VoicemeeterEngineState $VoicemeeterPath
    if (-not (Test-EngineValueEqual $after $Snapshot)) { throw 'Native engine restore readback did not match the snapshot.' }
    return $after
}

function Set-VoicemeeterEngineLatency {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VoicemeeterPath, [Parameter(Mandatory)][string]$BackupPath)
    if (-not [IO.Path]::IsPathRooted($BackupPath)) { throw 'An absolute backup file path is required.' }
    $before = Get-VoicemeeterEngineState $VoicemeeterPath
    # Even an idempotent Set requires a stopped engine; Get supports login preflight.
    Assert-EngineStopped
    $hasBackup = Test-Path -LiteralPath $BackupPath
    if ($hasBackup) {
        $original = Import-Clixml -LiteralPath $BackupPath -ErrorAction Stop
        Assert-EngineSnapshot $original
        if (-not (Test-EngineManagedValue $before) -and -not (Test-EngineValueEqual $before $original)) {
            throw 'VAIO latency changed outside this task; refusing to overwrite the conflicting value.'
        }
    }
    if ($before.Enabled) {
        return [pscustomobject]@{ Changed = $false; RestartRequired = $false; Before = $before; After = $before; BackupPath = $BackupPath }
    }
    if (-not $hasBackup) {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes([Management.Automation.PSSerializer]::Serialize($before, 5))
        $file = [IO.File]::Open($BackupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $file.Write($bytes, 0, $bytes.Length)
            $file.Flush($true)
        } finally { $file.Dispose() }
    }
    try {
        Assert-EngineStopped
        $current = Get-VoicemeeterEngineState $VoicemeeterPath
        if (-not (Test-EngineValueEqual $before $current)) { throw 'VAIO latency changed during setup.' }
        Write-EngineValue ([pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = $script:EngineLatency })
        $after = Get-VoicemeeterEngineState $VoicemeeterPath
        if (-not $after.Enabled) { throw 'Native engine latency did not read back.' }
        [pscustomobject]@{ Changed = $true; RestartRequired = $true; Before = $before; After = $after; BackupPath = $BackupPath }
    } catch {
        $failure = $_.Exception.Message
        try { $null = Restore-VoicemeeterEngineState $VoicemeeterPath $before }
        catch { throw ($failure + ' Rollback failed: ' + $_.Exception.Message + ' Backup: ' + $BackupPath) }
        throw ($failure + ' Original native engine value was restored.')
    }
}

Export-ModuleMember -Function Get-VoicemeeterEngineState, Set-VoicemeeterEngineLatency, Restore-VoicemeeterEngineState
