# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
Set-StrictMode -Version 2.0

# Native startup option semantics verified against this exact 1.1.3.0 image.
# SysTray=1 creates the notification icon; SysTrayShowOnRun=0 starts hidden.
$script:TrayHash = 'FC3ADB5F805F5294168CFE91193C501318395629400C0A4C38F7AB2427C6063A'
$script:TraySigner = '762B6D6B2958E709F24C8DEA080150E2D4FB5889'
$script:TrayKey = 'VB-Audio\VoiceMeeter'
$script:TrayNames = @('SysTray','SysTrayShowOnRun')

function Assert-TrayImage {
    param([string]$VoicemeeterPath)
    if (-not [IO.Path]::IsPathRooted($VoicemeeterPath) -or [IO.Path]::GetFileName($VoicemeeterPath) -ine 'voicemeeter.exe') {
        throw 'An absolute path to voicemeeter.exe is required.'
    }
    $version=(Get-Item -LiteralPath $VoicemeeterPath -ErrorAction Stop).VersionInfo
    if ($version.FileMajorPart -ne 1 -or $version.FileMinorPart -ne 1 -or $version.FileBuildPart -ne 3 -or $version.FilePrivatePart -ne 0 -or
        (Get-FileHash -LiteralPath $VoicemeeterPath -Algorithm SHA256 -ErrorAction Stop).Hash -ine $script:TrayHash) {
        throw 'Unsupported Voicemeeter build; expected the verified 1.1.3.0 image.'
    }
    $signature=Get-AuthenticodeSignature -LiteralPath $VoicemeeterPath -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ine $script:TraySigner) {
        throw 'Voicemeeter signature does not match the verified publisher.'
    }
}

function Get-TrayUserSid {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    try {$identity.User.Value} finally {$identity.Dispose()}
}
function Assert-TrayStopped {
    # Include other editions: all share this vendor configuration namespace.
    if (@(Get-Process -ErrorAction Stop | Where-Object {$_.ProcessName -like 'voicemeeter*'}).Count) {
        throw 'Voicemeeter must be stopped before changing native tray options.'
    }
}

function Read-TrayValues {
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser','Registry32')
    $key=$null
    try {
        $key=$base.OpenSubKey($script:TrayKey,$false)
        foreach($name in $script:TrayNames) {
            $exists=$null -ne $key -and $key.GetValueNames() -contains $name
            $value=$null
            if($exists){$value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
            [pscustomobject]@{Name=$name;Exists=$exists;Kind=$(if($exists){$key.GetValueKind($name).ToString()}else{$null});Value=$value}
        }
    } finally {if($key){$key.Dispose()};$base.Dispose()}
}

function Write-TrayValue {
    param($Row)
    $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser','Registry32')
    $key=$null
    try {
        $key=$base.OpenSubKey($script:TrayKey,$true)
        if ($Row.Exists) {
            if (-not $key) {$key=$base.CreateSubKey($script:TrayKey)}
            $value=$Row.Value
            switch ($Row.Kind) {
                'Binary' {$value=[byte[]]$value}
                'None' {$value=[byte[]]$value}
                'MultiString' {$value=[string[]]$value}
                'DWord' {$value=[int]$value}
                'QWord' {$value=[long]$value}
            }
            $key.SetValue($Row.Name,$value,[Microsoft.Win32.RegistryValueKind]$Row.Kind)
        } elseif ($key) {$key.DeleteValue($Row.Name,$false)}
    } finally {if($key){$key.Dispose()};$base.Dispose()}
}

function Assert-TraySnapshot {
    param($Snapshot)
    if ($Snapshot.Schema -ne 1 -or $Snapshot.ImageHash -cne $script:TrayHash -or $Snapshot.UserSid -cne (Get-TrayUserSid) -or
        $Snapshot.Key -cne $script:TrayKey -or @($Snapshot.Values).Count -ne 2) {throw 'Invalid native tray snapshot.'}
    for($i=0;$i -lt 2;$i++) {
        $r=$Snapshot.Values[$i]
        if ($r.Name -cne $script:TrayNames[$i] -or $r.Exists -isnot [bool]) {throw 'Invalid native tray snapshot target.'}
        if (-not $r.Exists) {
            if ($null -ne $r.Kind -or $null -ne $r.Value) {throw 'Invalid absent native tray value.'}
            continue
        }
        $valid=switch ($r.Kind) {
            'String' {$r.Value -is [string]}
            'ExpandString' {$r.Value -is [string]}
            'DWord' {$r.Value -is [int]}
            'QWord' {$r.Value -is [long]}
            'Binary' {$r.Value -is [byte[]]}
            'None' {$r.Value -is [byte[]]}
            'MultiString' {$r.Value -is [Collections.IList] -and @($r.Value | Where-Object {$_ -isnot [string]}).Count -eq 0}
            default {$false}
        }
        if (-not $valid) {throw 'Unsupported native tray snapshot value type.'}
    }
}

function Test-TrayValuesEnabled {
    param($Values)
    return ($Values[0].Exists -and $Values[0].Kind -ceq 'DWord' -and $Values[0].Value -eq 1 -and
        $Values[1].Exists -and $Values[1].Kind -ceq 'DWord' -and $Values[1].Value -eq 0)
}

function Get-VoicemeeterTrayState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VoicemeeterPath)
    Assert-TrayImage $VoicemeeterPath
    $values = @(Read-TrayValues)
    [pscustomobject]@{
        Schema = 1
        ImageHash = $script:TrayHash
        UserSid = Get-TrayUserSid
        Key = $script:TrayKey
        Values = $values
        Enabled = Test-TrayValuesEnabled $values
    }
}

function Restore-VoicemeeterTrayState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VoicemeeterPath,[Parameter(Mandatory)]$Snapshot)
    Assert-TrayImage $VoicemeeterPath
    Assert-TraySnapshot $Snapshot
    Assert-TrayStopped
    foreach ($row in $Snapshot.Values) { Write-TrayValue $row }
    $after = Get-VoicemeeterTrayState $VoicemeeterPath
    if (($after.Values | ConvertTo-Json -Depth 5 -Compress) -cne ($Snapshot.Values | ConvertTo-Json -Depth 5 -Compress)) {
        throw 'Native tray rollback readback did not match the snapshot.'
    }
    return $after
}

function Set-VoicemeeterTrayMode {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VoicemeeterPath,[Parameter(Mandatory)][string]$BackupPath)
    if (-not [IO.Path]::IsPathRooted($BackupPath)) {
        throw 'An absolute backup file path is required.'
    }
    $before = Get-VoicemeeterTrayState $VoicemeeterPath
    Assert-TraySnapshot $before
    # Preserve the first snapshot across login retries. CLIXML preserves exact registry types.
    if (Test-Path -LiteralPath $BackupPath) {
        Assert-TraySnapshot (Import-Clixml -LiteralPath $BackupPath -ErrorAction Stop)
    }
    if ($before.Enabled) {
        return [pscustomobject]@{
            Changed = $false
            RestartRequired = $false
            Before = $before
            After = $before
            BackupPath = $BackupPath
        }
    }
    Assert-TrayStopped
    if (-not (Test-Path -LiteralPath $BackupPath)) {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes([Management.Automation.PSSerializer]::Serialize($before, 8))
        $file = [IO.File]::Open($BackupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $file.Write($bytes, 0, $bytes.Length)
            $file.Flush($true)
        } finally { $file.Dispose() }
    }
    try {
        Assert-TrayStopped
        for ($i = 0; $i -lt 2; $i++) {
            Write-TrayValue ([pscustomobject]@{
                Name = $script:TrayNames[$i]
                Exists = $true
                Kind = 'DWord'
                Value = [int](1 - $i)
            })
        }
        $after = Get-VoicemeeterTrayState $VoicemeeterPath
        if (-not $after.Enabled) { throw 'Native tray options did not read back.' }
        [pscustomobject]@{
            Changed = $true
            RestartRequired = $true
            Before = $before
            After = $after
            BackupPath = $BackupPath
        }
    } catch {
        $failure = $_.Exception.Message
        try { $null = Restore-VoicemeeterTrayState $VoicemeeterPath $before }
        catch { throw ($failure + ' Rollback failed: ' + $_.Exception.Message + ' Backup: ' + $BackupPath) }
        throw ($failure + ' Original native tray values were restored.')
    }
}

Export-ModuleMember -Function Get-VoicemeeterTrayState,Set-VoicemeeterTrayMode,Restore-VoicemeeterTrayState
