# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-VoicemeeterPackage {
    [pscustomobject]@{
        Version = '1.1.3.0'
        Url = 'https://download.vb-audio.com/Download_CABLE/VoicemeeterSetup_v1130.zip'
        ArchiveSha256 = '75e797b24dd851f487c733f83cdab49f26aaa3d828da054b7ab31b56a1165acf'
        InstallerSha256 = 'eddadad3aaf047cca252831e11a054114a2f7c7cdbe74b904155be613d0600cd'
        Publisher = 'BUREL VINCENT Entrepreneur individuel'
    }
}

function New-DesktopAudioConfig {
    param([string]$Address, [int]$Port = 6980, [string]$StreamName = 'Windows')
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.ToString() -cne $Address) { throw 'Enter a complete IPv4 address, for example 192.0.2.20.' }
    $octets = $parsed.GetAddressBytes()
    if ($octets[0] -eq 0 -or $octets[0] -eq 127 -or $octets[0] -ge 224 -or $Address -eq '255.255.255.255') {
        throw 'The target must be a unicast LAN IPv4 address.'
    }
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'Port must be between 1024 and 65535.' }
    if ($StreamName -cnotmatch '^[A-Za-z0-9_-]{1,16}$') {
        throw 'Stream name must contain 1-16 ASCII letters, digits, underscores or hyphens.'
    }
    [pscustomobject]@{ Schema = 1; Address = $Address; Port = $Port; StreamName = $StreamName }
}

function Write-AudioJson {
    param([string]$Path, $Value)
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-VoicemeeterDirectory {
    $candidates = @()
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VB:Voicemeeter {17359A74-1236-5467}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\VB:Voicemeeter {17359A74-1236-5467}'
    )) {
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($entry -and $entry.PSObject.Properties['UninstallString']) {
            $uninstall = [string]$entry.UninstallString
            if ($uninstall -match '^"([^"]+\.exe)"') { $candidates += Split-Path $Matches[1] -Parent }
            elseif (Test-Path -LiteralPath $uninstall -PathType Leaf) { $candidates += Split-Path $uninstall -Parent }
        }
    }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'VB\Voicemeeter' }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'VB\Voicemeeter' }
    foreach ($directory in ($candidates | Select-Object -Unique)) {
        if ((Test-Path -LiteralPath (Join-Path $directory 'voicemeeter.exe')) -and
            (Test-Path -LiteralPath (Join-Path $directory 'VoicemeeterRemote64.dll'))) { return $directory }
    }
    return $null
}

function Assert-VoicemeeterInstaller {
    param([string]$Path)
    $package = Get-VoicemeeterPackage
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $package.InstallerSha256) {
        throw 'Installer SHA256 does not match the pinned official release.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -cne $package.Publisher) {
        throw 'Installer must have a valid VB-Audio publisher signature.'
    }
}

function Get-VoicemeeterInstallEvidence {
    param([string]$Directory = (Get-VoicemeeterDirectory))
    $issues = @(); $versions = @()
    $package = Get-VoicemeeterPackage
    foreach ($name in @('voicemeeter.exe', 'VoicemeeterRemote64.dll')) {
        $path = if ($Directory) { Join-Path $Directory $name } else { $null }
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $issues += "Missing application file: $name"; $versions += $null; continue
        }
        $info = (Get-Item -LiteralPath $path).VersionInfo
        $version = '{0}.{1}.{2}.{3}' -f $info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart
        $versions += $version
        if ($version -ne $package.Version) { $issues += "Unsupported application version: $name $version" }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.GetNameInfo('SimpleName', $false) -cne $package.Publisher) {
            $issues += "Unverified application signature: $name"
        }
    }
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceName='VB-Audio Voicemeeter VAIO'")
    $devices = @(Get-CimInstance Win32_PnPEntity -Filter "Name='VB-Audio Voicemeeter VAIO'")
    $service = Get-CimInstance Win32_SystemDriver -Filter "Name='VBVoicemeeterVAIOMME'"
    $driver = $null; $device = $null
    if ($drivers.Count -ne 1) { $issues += 'Expected one registered VAIO driver' }
    else {
        $driver = $drivers[0]
        if (-not $driver.IsSigned -or $driver.Signer -ne 'Microsoft Windows Hardware Compatibility Publisher' -or
            $driver.DriverVersion -ne '3.4.1.9' -or -not $driver.InfName) { $issues += 'VAIO driver version or signature does not match the supported package' }
        $matches = @($devices | Where-Object { $_.PNPDeviceID -eq $driver.DeviceID })
        if ($matches.Count -ne 1) { $issues += 'Registered VAIO device is missing or ambiguous' }
        else {
            $device = $matches[0]
            if ($device.ConfigManagerErrorCode -notin @(0,14)) { $issues += "VAIO device problem code: $($device.ConfigManagerErrorCode)" }
        }
    }
    if (-not $service -or -not $service.PathName -or -not (Test-Path -LiteralPath $service.PathName)) {
        $issues += 'VAIO driver service or binary is missing'
    }
    [pscustomobject]@{
        Complete = $issues.Count -eq 0
        Ready = ($issues.Count -eq 0 -and $device.ConfigManagerErrorCode -eq 0 -and $service.State -eq 'Running')
        Issues = $issues; Directory = $Directory; ApplicationVersion = $versions[0]; RemoteVersion = $versions[1]
        DriverVersion = $(if ($driver) { $driver.DriverVersion } else { $null })
        DeviceId = $(if ($device) { $device.PNPDeviceID } else { $null })
        DriverProblem = $(if ($device) { $device.ConfigManagerErrorCode } else { $null })
    }
}

function Get-VoicemeeterInstallResult {
    param([int]$ExitCode, $Evidence)
    # The pinned 1.1.3.0 installer returns 1 on BOTH its completed and warning
    # paths. An exit code is only a candidate result, never proof of installation.
    if ($ExitCode -notin @(0,1)) { throw "Voicemeeter installer returned unsupported result $ExitCode." }
    if (-not $Evidence.Complete) { throw ('Incomplete Voicemeeter installation: ' + ($Evidence.Issues -join '; ')) }
    return 'PendingReboot'
}

function Get-VoicemeeterInstaller {
    param([string]$CacheDirectory)
    $package = Get-VoicemeeterPackage
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    $archive = Join-Path $CacheDirectory 'VoicemeeterSetup_v1130.zip'
    $installer = Join-Path $CacheDirectory 'voicemeetersetup.exe'
    if (-not (Test-Path -LiteralPath $archive) -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $package.ArchiveSha256) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $package.Url -OutFile ($archive + '.download') -TimeoutSec 180
        if ((Get-FileHash -LiteralPath ($archive + '.download') -Algorithm SHA256).Hash -ine $package.ArchiveSha256) {
            throw 'Downloaded archive does not match the pinned official release.'
        }
        Move-Item -LiteralPath ($archive + '.download') -Destination $archive -Force
    }
    # Extract just the expected file; never execute scripts from the archive.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $matches = @($zip.Entries | Where-Object { $_.FullName -ieq 'voicemeetersetup.exe' })
        if ($matches.Count -ne 1) { throw 'Unexpected installer archive layout.' }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($matches[0], $installer, $true)
    } finally { $zip.Dispose() }
    Assert-VoicemeeterInstaller $installer
    return $installer
}

function Wait-Voicemeeter {
    param($Remote, [int]$TimeoutSeconds = 15)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { $null = $Remote.Dirty(); if ($Remote.Type() -gt 0) { return } } catch { }
        Start-Sleep -Milliseconds 150
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Voicemeeter did not become ready. Restart Windows if its driver was just installed.'
}

function Save-VoicemeeterXml {
    param($Remote, [string]$Path)
    $Remote.SetString('Command.Save', $Path)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $xml = New-Object Xml.XmlDocument
                $xml.Load($Path)
                if ($xml.DocumentElement) { return }
            } catch { }
        }
        Start-Sleep -Milliseconds 100
    } while ($timer.Elapsed.TotalSeconds -lt 5)
    throw 'Voicemeeter did not save a readable XML backup.'
}

function Get-DesktopStreamSlot {
    param($Remote, $Config, [int]$OwnedSlot = -1)
    if ($OwnedSlot -ge 0 -and $OwnedSlot -lt 4) { return $OwnedSlot }
    # Standard supports four outgoing audio streams. Leave enabled slots alone.
    for ($slot = 0; $slot -lt 4; $slot++) {
        if ($Remote.GetFloat("vban.outstream[$slot].on") -eq 0) { return $slot }
    }
    throw 'All four VBAN output slots are in use; no stream has been overwritten.'
}

function Get-DesktopAudioPlan {
    param($Config, [int]$Slot)
    if ($Slot -lt 0 -or $Slot -gt 3) { throw 'Invalid VBAN audio slot.' }
    $checked = New-DesktopAudioConfig $Config.Address $Config.Port $Config.StreamName
    # BUS B is dedicated to the Windows virtual input, excluding hardware mics.
    [ordered]@{
        'Strip[0].B1' = 0
        'Strip[1].B1' = 0
        'Strip[2].A1' = 0
        'Strip[2].B1' = 1
        'Strip[2].Mute' = 0
        'Strip[2].Gain' = 0
        'Bus[1].Mute' = 0
        'Bus[1].Gain' = 0
        'Option.sr' = 48000
        "vban.outstream[$Slot].name" = $checked.StreamName
        "vban.outstream[$Slot].ip" = $checked.Address
        "vban.outstream[$Slot].port" = $checked.Port
        "vban.outstream[$Slot].sr" = 48000
        "vban.outstream[$Slot].channel" = 2
        "vban.outstream[$Slot].bit" = 1
        "vban.outstream[$Slot].route" = 1
    }
}

function Test-DesktopAudioPlan {
    param($Remote, $Plan)
    $null = $Remote.Dirty()
    foreach ($name in $Plan.Keys) {
        if ($Plan[$name] -is [string]) {
            if ($Remote.GetString($name) -cne $Plan[$name]) { return $false }
        } elseif ([Math]::Abs($Remote.GetFloat($name) - [float]$Plan[$name]) -gt 0.01) { return $false }
    }
    return $true
}

function Get-DesktopAudioSnapshot {
    param($Remote, $Config, [int]$Slot)
    # A failed first Setup can leave native backups without settings.json.
    # This documentation address generates parameter keys only; no connection,
    # stream or plan is applied. Every returned value is read from the mixer.
    if ($null -eq $Config) { $Config = New-DesktopAudioConfig '192.0.2.1' }
    $keys = Get-DesktopAudioPlan $Config $Slot
    $keys['vban.Enable'] = 0
    $keys["vban.outstream[$Slot].on"] = 0
    $snapshot = [ordered]@{}
    $null = $Remote.Dirty()
    foreach ($name in $keys.Keys) {
        $snapshot[$name] = if ($keys[$name] -is [string]) { $Remote.GetString($name) } else { $Remote.GetFloat($name) }
    }
    return $snapshot
}

function Restore-VoicemeeterXml {
    param($Remote, [string]$Path, $Expected, [int]$TimeoutSeconds = 10)
    $Remote.SetString('Command.Load', $Path)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 100
        try {
            if (Test-DesktopAudioPlan $Remote $Expected) { return }
            # Standard can omit an inactive stream's route when loading XML.
            # Once every other saved parameter matches, restore only those
            # route values explicitly, then verify the complete snapshot again.
            $mismatches = @()
            foreach ($name in $Expected.Keys) {
                $actual = if ($Expected[$name] -is [string]) { $Remote.GetString($name) } else { $Remote.GetFloat($name) }
                if ($actual -cne $Expected[$name]) { $mismatches += $name }
            }
            if ($mismatches.Count -and -not @($mismatches | Where-Object { $_ -notmatch '^vban\.outstream\[[0-3]\]\.route$' }).Count) {
                foreach ($name in $mismatches) {
                    $enabledName = $name.Substring(0, $name.Length - 'route'.Length) + 'on'
                    if ($Expected.Contains($enabledName) -and $Expected[$enabledName] -eq 0 -and $Remote.GetFloat($enabledName) -eq 0) {
                        $Remote.SetFloat($name, [float]$Expected[$name])
                    }
                }
            }
        } catch { }
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Voicemeeter XML restore did not match the saved parameters; backup has been retained.'
}

function Set-DesktopAudioPlan {
    param($Remote, $Config, [int]$Slot, [int]$TimeoutSeconds = 15)
    if ($Remote.Type() -ne 1) { throw 'Only Voicemeeter Standard is supported. Leave Banana/Potato unchanged.' }
    $plan = Get-DesktopAudioPlan $Config $Slot
    $Remote.SetFloat("vban.outstream[$Slot].on", 0)
    foreach ($name in $plan.Keys) {
        if ($plan[$name] -is [string]) { $Remote.SetString($name, $plan[$name]) }
        else { $Remote.SetFloat($name, [float]$plan[$name]) }
    }
    $Remote.SetFloat('vban.Enable', 1)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            if ((Test-DesktopAudioPlan $Remote $plan) -and $Remote.GetFloat('vban.Enable') -eq 1) {
                $Remote.SetFloat("vban.outstream[$Slot].on", 1)
                Start-Sleep -Milliseconds 150
                $null = $Remote.Dirty()
                if ($Remote.GetFloat("vban.outstream[$Slot].on") -eq 1) { return }
            }
        } catch { }
        Start-Sleep -Milliseconds 150
    } while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Voicemeeter parameters did not match the requested VBAN configuration.'
}

function Get-VoicemeeterEndpoint {
    param([object[]]$Endpoints)
    $identified = @($Endpoints | Where-Object { $_.PSObject.Properties['WaveInterface'] -and $_.WaveInterface -match 'vbvoicemeetervaio2023_out[1-8]_wave_' })
    if ($identified.Count -gt 0) {
        $main = @($identified | Where-Object { $_.Active -and $_.ParentDevice -and $_.WaveInterface -match 'vbvoicemeetervaio2023_out6_wave_' })
        if ($main.Count -ne 1) { throw 'Expected one active Standard VAIO 6 playback endpoint.' }
        return $main[0]
    }
    $found = @($Endpoints | Where-Object {
        $_.Active -and $_.Name -match '^Voicemeeter Input(?:\s*\(VB-Audio Voicemeeter VAIO\))?$'
    })
    if ($found.Count -ne 1) { throw 'Expected one active Voicemeeter Input playback endpoint. Restart Windows after installation.' }
    return $found[0]
}

function Get-VoicemeeterExtraEndpoints {
    param([object[]]$Endpoints, $Target)
    if (-not $Target.PSObject.Properties['WaveInterface'] -or
        $Target.WaveInterface -notmatch 'vbvoicemeetervaio2023_out6_wave_' -or -not $Target.ParentDevice) { return @() }
    return @($Endpoints | Where-Object {
        $_.Id -like '{0.0.0.00000000}.*' -and $_.Id -ne $Target.Id -and $_.State -eq 1 -and $_.ParentDevice -eq $Target.ParentDevice -and
        $_.WaveInterface -match 'vbvoicemeetervaio2023_out[1-578]_wave_'
    })
}

function Set-EndpointVisibilityState {
    param([object[]]$Snapshot, [bool]$Visible)
    $failures = @()
    foreach ($endpoint in $Snapshot) {
        try {
            [LanAudioBridge.WindowsAudio.Endpoints]::SetVisibility($endpoint.Id, $Visible)
            $expected = if ($Visible) { 1 } else { 2 }
            if ([LanAudioBridge.WindowsAudio.Endpoints]::GetState($endpoint.Id) -ne $expected) { throw 'Endpoint state readback did not match' }
        } catch { $failures += "$($endpoint.Id): $($_.Exception.Message)" }
    }
    if ($failures.Count) { throw ('Playback endpoint update failed: ' + ($failures -join '; ')) }
}

function ConvertTo-ProcessPowerSnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot) { throw 'A process power snapshot is required.' }
    $copy = New-Object LanAudioBridge.WindowsAudio.ProcessPowerSnapshot
    $copy.ProcessId = [int]$Snapshot.ProcessId
    $copy.ExecutablePath = [string]$Snapshot.ExecutablePath
    $copy.CreationTime = [long]$Snapshot.CreationTime
    $copy.ControlMask = [uint32]$Snapshot.ControlMask
    $copy.StateMask = [uint32]$Snapshot.StateMask
    return $copy
}

function Get-VoicemeeterRuntimePowerPolicy {
    param([Parameter(Mandatory = $true)][int]$ProcessId, [string]$Directory = (Get-VoicemeeterDirectory))
    if (-not $Directory) { throw 'Voicemeeter installation directory was not found.' }
    return [LanAudioBridge.WindowsAudio.ProcessRuntime]::Get($ProcessId, (Join-Path $Directory 'voicemeeter.exe'))
}

function Set-VoicemeeterRuntimePowerPolicy {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [switch]$DisableExecutionSpeed
    )
    if (Test-Path -LiteralPath $BackupPath) { throw 'Runtime power backup already exists; restore or retain it before applying another policy.' }
    $before = ConvertTo-ProcessPowerSnapshot $Snapshot
    $after = [LanAudioBridge.WindowsAudio.ProcessRuntime]::DesiredPolicy($before, [bool]$DisableExecutionSpeed)
    # Prepared is sufficient for recovery even if the launcher stops immediately after the native write.
    $record = [pscustomobject]@{ Schema = 1; Status = 'Prepared'; Before = $before; After = $after }
    Write-AudioJson -Path $BackupPath -Value $record
    $change = [LanAudioBridge.WindowsAudio.ProcessRuntime]::Apply($before, [bool]$DisableExecutionSpeed)
    $record.After = $change.After
    $record.Status = 'Applied'
    Write-AudioJson -Path $BackupPath -Value $record
    return $record
}

function Restore-VoicemeeterRuntimePowerPolicy {
    param([Parameter(Mandatory = $true)][string]$BackupPath)
    $record = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    if ($record.Schema -ne 1 -or $record.Status -notin @('Prepared', 'Applied', 'Restored')) { throw 'Unsupported runtime power backup.' }
    $change = New-Object LanAudioBridge.WindowsAudio.ProcessPowerChange
    $change.Before = ConvertTo-ProcessPowerSnapshot $record.Before
    $change.After = ConvertTo-ProcessPowerSnapshot $record.After
    $current = [LanAudioBridge.WindowsAudio.ProcessRuntime]::Get($change.Before.ProcessId, $change.Before.ExecutablePath)
    if ($current.CreationTime -ne $change.Before.CreationTime) { throw 'Runtime power backup belongs to a previous process instance; the current process was left unchanged.' }
    if ($current.ControlMask -ne $change.Before.ControlMask -or $current.StateMask -ne $change.Before.StateMask) {
        $current = [LanAudioBridge.WindowsAudio.ProcessRuntime]::Restore($change)
    }
    $record.Status = 'Restored'
    Write-AudioJson -Path $BackupPath -Value $record
    return $current
}

Export-ModuleMember -Function *-*
