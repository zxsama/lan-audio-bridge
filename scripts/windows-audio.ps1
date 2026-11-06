# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
# SPDX-License-Identifier: MIT
# Windows PowerShell 5.1 and PowerShell 7, Windows x64.
[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Resume', 'Start', 'Status', 'Restore', 'Plan')]
    [string]$Action = 'Setup',
    [string]$Address,
    [int]$Port = 6980,
    [string]$StreamName = 'Windows'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'windows\Voicemeeter.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'windows\DriverOptions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'windows\TrayOptions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'windows\EngineOptions.psm1') -Force
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LanAudioBridge\WindowsAudio'
$settingsPath = Join-Path $stateRoot 'settings.json'
$backupPath = Join-Path $stateRoot 'original.json'
$endpointBackupPath = Join-Path $stateRoot 'endpoints-original.json'
$programRoot = Join-Path $stateRoot 'program'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'LanAudioBridgeAudio'
$remote = $null
$transcribing = $false
$mutex = $null
$lockHeld = $false
$runtimePolicyBackup = $null

function Read-Settings {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }
    $value = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($value.Schema -ne 1) { throw 'Unsupported local configuration schema.' }
    $null = New-DesktopAudioConfig $value.Address $value.Port $value.StreamName
    return $value
}

function Get-StartupValue {
    $entry = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
    if ($entry -and $entry.PSObject.Properties[$runName]) {
        return [pscustomobject]@{ Exists = $true; Value = [string]$entry.$runName }
    }
    return [pscustomobject]@{ Exists = $false; Value = $null }
}

function Set-StartupValue {
    param($Value)
    if ($Value.Exists) {
        New-Item -Path $runKey -Force | Out-Null
        New-ItemProperty -LiteralPath $runKey -Name $runName -Value $Value.Value -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $runKey -Name $runName -ErrorAction SilentlyContinue
    }
}

function Get-DefaultEndpoints {
    $result = @()
    foreach ($role in 0..2) { $result += [pscustomobject]@{ Role = $role; Id = [LanAudioBridge.WindowsAudio.Endpoints]::GetDefault($role) } }
    return $result
}

function Restore-DefaultEndpoints {
    param($Defaults)
    $active = @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender() | Where-Object Active | ForEach-Object Id)
    foreach ($endpoint in $Defaults) {
        if ($endpoint.Id -and $active -notcontains $endpoint.Id) {
            throw 'An original playback device is unavailable. Reconnect it and run Restore again.'
        }
    }
    foreach ($endpoint in $Defaults) {
        if ($endpoint.Id) { [LanAudioBridge.WindowsAudio.Endpoints]::SetDefault($endpoint.Id, [int]$endpoint.Role) }
    }
}

function Copy-LocalProgram {
    New-Item -ItemType Directory -Path (Join-Path $programRoot 'windows') -Force | Out-Null
    foreach ($relative in @('windows-audio.ps1', 'windows-driver-volume.ps1',
        'windows\Voicemeeter.psm1', 'windows\AudioInterop.cs', 'windows\DriverOptions.psm1',
        'windows\TrayOptions.psm1', 'windows\EngineOptions.psm1')) {
        $source = Join-Path $PSScriptRoot $relative
        $destination = Join-Path $programRoot $relative
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }
}

function Test-DriverVolumeEnabled {
    param($State)
    return $State.RuntimeEnabled -and @($State.Registry | Where-Object {
        -not $_.Exists -or $_.Kind -cne 'DWord' -or $_.Value -ne 1
    }).Count -eq 0
}

function Invoke-DriverVolumeAction {
    param([ValidateSet('Enable', 'Restore')][string]$DriverAction)
    $child = Join-Path $PSScriptRoot 'windows-driver-volume.ps1'
    if (-not (Test-Path -LiteralPath $child -PathType Leaf)) {
        throw 'The native driver option helper is missing. Run Setup from the complete package.'
    }
    $resultPath = Join-Path $stateRoot 'driver-volume-result.json'
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # The elevated child accepts only this fixed action, with no path or command arguments.
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $child + '" -Action ' + $DriverAction
    Write-Output 'Windows will request administrator permission for the native volume-control option.'
    $process = Start-Process -FilePath $psExe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        throw 'The native driver option helper did not return a result; audio configuration was not continued.'
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($result.Schema -ne 1 -or $result.Action -cne $DriverAction -or
        $process.ExitCode -ne 0 -or -not $result.Succeeded) {
        $detail = if ($result.PSObject.Properties['Error']) { $result.Error } else { 'Invalid helper result.' }
        throw ('Native driver option action failed: ' + $detail)
    }
}

function Ensure-DriverVolumeControl {
    param([string]$Directory, [switch]$ReadOnly)
    $panel = Join-Path $Directory 'VBVoicemeeterVAIO_ControlPanel.exe'
    $state = Get-DriverVolumeControlState -ControlPanelPath $panel
    if ($ReadOnly) {
        if (-not (Test-DriverVolumeEnabled $state)) {
            throw 'Native Windows volume control is disabled. Run Setup once to repair it; startup does not request administrator permission.'
        }
        return
    }
    $originalPath = Join-Path $stateRoot 'driver-volume-original.json'
    if (-not (Test-Path -LiteralPath $originalPath)) {
        # Preserve the first state even when a previous external setup enabled it.
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($state | ConvertTo-Json -Depth 6))
        $file = [IO.File]::Open($originalPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) }
        finally { $file.Dispose() }
    }
    if (Test-DriverVolumeEnabled $state) { return }
    Invoke-DriverVolumeAction -DriverAction Enable
    $actual = Get-DriverVolumeControlState -ControlPanelPath $panel
    if (-not (Test-DriverVolumeEnabled $actual)) {
        throw 'The native Windows volume-control option did not pass independent readback.'
    }
}

function Restore-DriverVolumeControl {
    param([string]$Directory)
    $originalPath = Join-Path $stateRoot 'driver-volume-original.json'
    if (-not (Test-Path -LiteralPath $originalPath)) { return }
    $snapshot = Get-Content -LiteralPath $originalPath -Raw | ConvertFrom-Json
    $panel = Join-Path $Directory 'VBVoicemeeterVAIO_ControlPanel.exe'
    $current = Get-DriverVolumeControlState -ControlPanelPath $panel
    if (($current | ConvertTo-Json -Depth 6 -Compress) -ceq ($snapshot | ConvertTo-Json -Depth 6 -Compress)) { return }
    Invoke-DriverVolumeAction -DriverAction Restore
    $actual = Get-DriverVolumeControlState -ControlPanelPath $panel
    if (($actual | ConvertTo-Json -Depth 6 -Compress) -cne ($snapshot | ConvertTo-Json -Depth 6 -Compress)) {
        throw 'The original native Windows volume-control option did not pass independent readback.'
    }
}

function Set-StartupAction {
    param([string]$StartupAction)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = '"' + $psExe + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
        (Join-Path $programRoot 'windows-audio.ps1') + '" -Action ' + $StartupAction
    if ($command.Length -gt 260) { throw 'The local user profile path is too long for a Windows Run startup entry.' }
    Set-StartupValue ([pscustomobject]@{ Exists = $true; Value = $command })
}

function Connect-Remote {
    param([string]$Directory, [switch]$StartIfNeeded, [string]$ProfilePath)
    $connection = New-Object LanAudioBridge.WindowsAudio.VoicemeeterRemote((Join-Path $Directory 'VoicemeeterRemote64.dll'))
    try {
        $login = $connection.Login()
        if ($login -eq 1 -and $StartIfNeeded) {
            $parameters = @{}
            $profile = if ($ProfilePath) { $ProfilePath } else { Join-Path $stateRoot 'desktop.xml' }
            if (Test-Path -LiteralPath $profile) { $parameters.ArgumentList = '-l"' + $profile + '"' }
            Start-Process -FilePath (Join-Path $Directory 'voicemeeter.exe') -WindowStyle Hidden @parameters | Out-Null
        }
        Wait-Voicemeeter $connection
        if ($connection.Type() -ne 1) { throw 'Voicemeeter Banana/Potato is running. This script configures Standard only.' }
        return $connection
    } catch { $connection.Dispose(); throw }
}

function Save-OriginalMixerState {
    param($Connection, $Config)
    $originalXml = Join-Path $stateRoot 'original.xml'
    if (Test-Path -LiteralPath $originalXml) { return }
    $profile = Join-Path $stateRoot ('original-pending-' + [Guid]::NewGuid().ToString('N') + '.xml')
    Save-VoicemeeterXml $Connection $profile
    $expected = [ordered]@{}
    foreach ($slot in 0..3) {
        $snapshot = Get-DesktopAudioSnapshot $Connection $Config $slot
        foreach ($key in $snapshot.Keys) { $expected[$key] = $snapshot[$key] }
    }
    # Publish XML last: a failed first backup must not suppress a complete retry.
    Write-AudioJson (Join-Path $stateRoot 'original-parameters.json') $expected
    Move-Item -LiteralPath $profile -Destination $originalXml
}

function Update-NativePlaybackOptions {
    param($Connection, [string]$Directory, $Config, [switch]$Restore)
    $exe = Join-Path $Directory 'voicemeeter.exe'
    $trayBefore = Get-VoicemeeterTrayState -VoicemeeterPath $exe
    $engineBefore = Get-VoicemeeterEngineState -VoicemeeterPath $exe
    $trayBackup = Join-Path $stateRoot 'tray-original.clixml'
    $engineBackup = Join-Path $stateRoot 'engine-original.clixml'
    if ($Restore) {
        if (-not (Test-Path -LiteralPath $trayBackup) -and -not (Test-Path -LiteralPath $engineBackup)) { return $Connection }
    } elseif ($trayBefore.Enabled -and $engineBefore.Enabled) { return $Connection }

    # Preferences are read at application startup. Preserve every output slot
    # before a single orderly restart; an inactive slot is still user state.
    $profile = Join-Path $stateRoot ('native-restart-' + [Guid]::NewGuid().ToString('N') + '.xml')
    Save-VoicemeeterXml $Connection $profile
    $expected = [ordered]@{}
    foreach ($slot in 0..3) {
        $snapshot = Get-DesktopAudioSnapshot $Connection $Config $slot
        foreach ($key in $snapshot.Keys) { $expected[$key] = $snapshot[$key] }
    }
    Write-AudioJson ($profile + '.json') $expected
    $mixers = @(Get-Process -Name voicemeeter -ErrorAction Stop | Where-Object { $_.Path -ieq $exe })
    if ($mixers.Count -ne 1) { throw 'Expected one mixer before the native preference update.' }
    $Connection.SetFloat('Command.Shutdown', 1)
    if (-not $mixers[0].WaitForExit(10000)) { throw 'Voicemeeter did not stop; native preferences were left unchanged.' }
    $Connection.Dispose()
    $next = $null
    try {
        if ($Restore) {
            if (Test-Path -LiteralPath $trayBackup) {
                $null = Restore-VoicemeeterTrayState $exe (Import-Clixml -LiteralPath $trayBackup)
            }
            if (Test-Path -LiteralPath $engineBackup) {
                $null = Restore-VoicemeeterEngineState $exe (Import-Clixml -LiteralPath $engineBackup)
            }
        } else {
            $null = Set-VoicemeeterTrayMode $exe $trayBackup
            $null = Set-VoicemeeterEngineLatency $exe $engineBackup
        }
        $next = Connect-Remote $Directory -StartIfNeeded -ProfilePath $profile
        Restore-VoicemeeterXml $next $profile $expected
        return $next
    } catch {
        $failure = $_
        # If startup failed, recover the prior preferences and original session.
        # Do not terminate a process that did start merely to hide a verification error.
        $running = @(Get-Process -Name voicemeeter -ErrorAction SilentlyContinue)
        if (-not $running.Count) {
            try { $null = Restore-VoicemeeterTrayState $exe $trayBefore } catch { Write-Warning $_.Exception.Message }
            try { $null = Restore-VoicemeeterEngineState $exe $engineBefore } catch { Write-Warning $_.Exception.Message }
            try {
                $recovered = Connect-Remote $Directory -StartIfNeeded -ProfilePath $profile
                try { Restore-VoicemeeterXml $recovered $profile $expected } finally { $recovered.Dispose() }
            } catch { Write-Warning ('Mixer session recovery failed: ' + $_.Exception.Message) }
        }
        if ($next) { $next.Dispose() }
        throw $failure
    }
}

function Enable-BackgroundPlayback {
    param([string]$Directory)
    $expectedPath = Join-Path $Directory 'voicemeeter.exe'
    $mixers = @(Get-Process -Name voicemeeter -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $expectedPath })
    if ($mixers.Count -ne 1) { throw 'Expected exactly one running Voicemeeter Standard process.' }
    $current = Get-VoicemeeterRuntimePowerPolicy -ProcessId $mixers[0].Id -Directory $Directory
    $path = Join-Path $stateRoot ('runtime-power-' + $current.ProcessId + '-' + $current.CreationTime + '.json')
    if (Test-Path -LiteralPath $path) {
        $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($saved.Status -eq 'Applied' -and $current.ControlMask -eq $saved.After.ControlMask -and
            $current.StateMask -eq $saved.After.StateMask) { return [pscustomobject]@{ Path = $path; Changed = $false } }
        if ($saved.Status -ne 'Restored' -or $current.ControlMask -ne $saved.Before.ControlMask -or
            $current.StateMask -ne $saved.Before.StateMask) {
            throw 'The saved process policy differs from the running mixer; restore it before reconfiguring.'
        }
        Move-Item -LiteralPath $path -Destination ($path + '.restored-' + [Guid]::NewGuid().ToString('N'))
    }
    $null = Set-VoicemeeterRuntimePowerPolicy -Snapshot $current -BackupPath $path
    return [pscustomobject]@{ Path = $path; Changed = $true }
}

function Restore-BackgroundPlayback {
    param([string]$Directory)
    $mixers = @(Get-Process -Name voicemeeter -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -ieq (Join-Path $Directory 'voicemeeter.exe')
    })
    foreach ($mixer in $mixers) {
        $current = Get-VoicemeeterRuntimePowerPolicy -ProcessId $mixer.Id -Directory $Directory
        $path = Join-Path $stateRoot ('runtime-power-' + $current.ProcessId + '-' + $current.CreationTime + '.json')
        if (Test-Path -LiteralPath $path) { $null = Restore-VoicemeeterRuntimePowerPolicy -BackupPath $path }
    }
}

function Save-ExtraEndpointBackup {
    param([object[]]$Endpoints)
    $saved = @()
    if (Test-Path -LiteralPath $endpointBackupPath) {
        $saved = @((Get-Content -LiteralPath $endpointBackupPath -Raw | ConvertFrom-Json).Endpoints)
    }
    foreach ($endpoint in $Endpoints) {
        if (@($saved | Where-Object { $_.Id -eq $endpoint.Id }).Count -eq 0) { $saved += $endpoint }
    }
    Write-AudioJson $endpointBackupPath ([pscustomobject]@{ Schema = 1; Endpoints = @($saved) })
}

function Protect-PendingRebootOutput {
    $all = @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender())
    try { $main = Get-VoicemeeterEndpoint $all }
    catch {
        # A correctly registered driver can expose its endpoints only after a
        # reboot (CM_PROB_NEED_RESTART). Cleanup must not cancel that continuation.
        Write-Output 'Playback endpoint cleanup deferred until the driver is ready after reboot.'
        return
    }
    $extra = @(Get-VoicemeeterExtraEndpoints $all $main)
    if (-not $extra.Count) { return }
    Save-ExtraEndpointBackup $extra
    $before = @(Get-DefaultEndpoints)
    $original = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    $vaioIds = @($extra | ForEach-Object Id) + @($main.Id)
    try {
        # Keep existing speakers working until the required reboot/configuration.
        foreach ($current in $before) {
            if ($vaioIds -contains $current.Id) {
                $prior = @($original.Defaults | Where-Object { $_.Role -eq $current.Role })
                if ($prior.Count -ne 1 -or -not $prior[0].Id -or $vaioIds -contains $prior[0].Id -or
                    @($all | Where-Object { $_.Id -eq $prior[0].Id -and $_.Active }).Count -ne 1) {
                    throw 'Cannot restore the original output before reboot. Reconnect it and retry Setup.'
                }
                [LanAudioBridge.WindowsAudio.Endpoints]::SetDefault($prior[0].Id, [int]$current.Role)
            }
        }
        Set-EndpointVisibilityState $extra $false
    } catch {
        $failure = $_
        try { Set-EndpointVisibilityState $extra $true } catch { Write-Warning $_.Exception.Message }
        try { Restore-DefaultEndpoints $before } catch { Write-Warning $_.Exception.Message }
        throw $failure
    }
    Write-Output 'Unused VAIO playback endpoints disabled; original speakers retained until configuration after reboot.'
}

try {
    if ($Action -eq 'Plan') {
        $config = New-DesktopAudioConfig $Address $Port $StreamName
        Get-DesktopAudioPlan $config 0 | ConvertTo-Json
        exit 0
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess -or
        $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Use 64-bit PowerShell on Windows x64.' }
    if (-not ('LanAudioBridge.WindowsAudio.Endpoints' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'windows\AudioInterop.cs')
    }
    $directory = Get-VoicemeeterDirectory
    $settings = Read-Settings
    if ($Action -eq 'Status') {
        [pscustomobject]@{
            InstalledDirectory = $directory
            Configuration = $settings
            PlaybackDevices = @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender())
            DefaultPlayback = @(Get-DefaultEndpoints)
            Startup = Get-StartupValue
            OriginalBackupAvailable = Test-Path -LiteralPath $backupPath
        } | ConvertTo-Json -Depth 6
        exit 0
    }
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex = New-Object Threading.Mutex($false, ('Local\LanAudioBridgeWindowsAudio-' + $userId))
    try { $lockHeld = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockHeld = $true }
    if (-not $lockHeld) { throw 'Another Windows audio setup or startup is already running.' }
    New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    Start-Transcript -LiteralPath (Join-Path $stateRoot 'setup.log') -Append | Out-Null
    $transcribing = $true

    if ($Action -eq 'Start') {
        if (-not $settings -or $settings.Status -ne 'Ready') { throw 'Complete Setup before starting the audio bridge.' }
        if (-not $directory) { throw 'Voicemeeter is no longer installed. Run Setup.' }
        Ensure-DriverVolumeControl -Directory $directory -ReadOnly
        $remote = Connect-Remote $directory -StartIfNeeded
        $runtimePolicyBackup = Enable-BackgroundPlayback $directory
        if ((Get-VoicemeeterTrayState (Join-Path $directory 'voicemeeter.exe')).Enabled) { $remote.SetFloat('Command.Show', 0) }
        Write-Output 'Voicemeeter Standard is running with background timer protection.'
        exit 0
    }

    if ($Action -eq 'Restore') {
        if (-not (Test-Path -LiteralPath $backupPath)) { throw 'No original configuration backup is available.' }
        $original = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        $profile = Join-Path $stateRoot 'original.xml'
        if (Test-Path -LiteralPath $endpointBackupPath) {
            $endpointSnapshot = Get-Content -LiteralPath $endpointBackupPath -Raw | ConvertFrom-Json
            $present = @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender() | Where-Object { $_.State -in @(1,2) } | ForEach-Object Id)
            $restorable = @($endpointSnapshot.Endpoints | Where-Object { $present -contains $_.Id })
            if ($restorable.Count -ne @($endpointSnapshot.Endpoints).Count) {
                Write-Warning 'Some saved auxiliary endpoints no longer exist; continuing to restore Windows output and startup settings.'
            }
            try { Set-EndpointVisibilityState $restorable $true }
            catch { Write-Warning "Auxiliary endpoint restore incomplete: $($_.Exception.Message)" }
        }
        # Validate original Windows devices before changing the mixer.
        $active = @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender() | Where-Object Active | ForEach-Object Id)
        foreach ($endpoint in $original.Defaults) {
            if ($endpoint.Id -and $active -notcontains $endpoint.Id) { throw 'Reconnect the original playback device, then run Restore again.' }
        }
        $mixerRestored = $false
        if ($directory -and (Test-Path -LiteralPath $profile)) {
            $remote = Connect-Remote $directory -StartIfNeeded
            $parametersFile = Join-Path $stateRoot 'original-parameters.json'
            try {
                if (Test-Path -LiteralPath $parametersFile) {
                    $storedParameters = Get-Content -LiteralPath $parametersFile -Raw | ConvertFrom-Json
                    $expected = [ordered]@{}
                    foreach ($property in $storedParameters.PSObject.Properties) { $expected[$property.Name] = $property.Value }
                    Restore-VoicemeeterXml $remote $profile $expected
                    $mixerRestored = $true
                } else {
                    $remote.SetString('Command.Load', $profile)
                    Write-Warning 'Legacy XML submitted without a parameter snapshot; verify the mixer configuration in Voicemeeter.'
                }
            } catch { Write-Warning "Mixer restore incomplete: $($_.Exception.Message)" }
            try { Restore-BackgroundPlayback $directory }
            catch { Write-Warning "Background process policy restore incomplete: $($_.Exception.Message)" }
            # Native setup may have completed before the first Ready settings were saved.
            try { $remote = Update-NativePlaybackOptions $remote $directory $settings -Restore }
            catch { Write-Warning "Native playback preferences restore incomplete: $($_.Exception.Message)" }
        }
        if ($directory) {
            try { Restore-DriverVolumeControl -Directory $directory }
            catch { Write-Warning "Native volume option restore incomplete: $($_.Exception.Message)" }
        }
        Restore-DefaultEndpoints $original.Defaults
        Set-StartupValue $original.Startup
        if ($settings) { $settings.Status = 'Restored'; Write-AudioJson $settingsPath $settings }
        Write-Output 'Original playback defaults and startup entry restored. Voicemeeter remains installed.'
        if ($mixerRestored) { Write-Output 'The saved mixer parameters were restored and verified.' }
        else { Write-Output 'Mixer restoration was not verified; see the preceding messages and retained XML backup.' }
        exit 0
    }

    if ($Action -eq 'Resume') {
        if (-not $settings) { throw 'No pending configuration. Run Setup first.' }
        $Address = $settings.Address; $Port = $settings.Port; $StreamName = $settings.StreamName
    } elseif (-not $Address) {
        if ($settings) {
            $Address = $settings.Address
            if (-not $PSBoundParameters.ContainsKey('Port')) { $Port = $settings.Port }
            if (-not $PSBoundParameters.ContainsKey('StreamName')) { $StreamName = $settings.StreamName }
        }
        else { $Address = Read-Host 'NAS IPv4 address' }
    }
    $config = New-DesktopAudioConfig $Address $Port $StreamName
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    Copy-LocalProgram
    if ($settings -and $settings.Status -eq 'InstallFailed' -and $directory) {
        $installed = Get-VoicemeeterInstallEvidence $directory
        if (-not $installed.Complete) { throw ('Existing installation is incomplete: ' + ($installed.Issues -join '; ')) }
        # Recover the old return-code-only failure without reinstalling drivers.
        $settings.Status = 'PendingReboot'
        Write-AudioJson $settingsPath $settings
        Set-StartupAction 'Resume'
        Write-Output 'Application and signed VAIO driver verified; recovered the pending-reboot configuration.'
    }
    if ($settings -and $settings.Status -eq 'PendingReboot' -and $settings.InstallBoot -eq $boot) {
        try { Protect-PendingRebootOutput }
        catch { Write-Warning "Playback endpoint cleanup deferred: $($_.Exception.Message)" }
        Write-Output 'Voicemeeter requires a Windows restart. Configuration will resume at the next sign-in.'
        exit 3010
    }
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Write-AudioJson $backupPath ([pscustomobject]@{
            Schema = 1; Defaults = @(Get-DefaultEndpoints); Startup = Get-StartupValue
        })
    }

    if (-not $directory) {
        if ($Action -eq 'Resume') { throw 'Voicemeeter installation was not detected after reboot. Run Setup to retry.' }
        Write-Output 'Downloading Voicemeeter Standard 1.1.3.0 from VB-Audio (Donationware).'
        Write-Output 'Origin and support: https://voicemeeter.com/ -- donations and licenses support VB-Audio.'
        $installer = Get-VoicemeeterInstaller (Join-Path $stateRoot 'downloads')
        $previousStartup = Get-StartupValue
        $pending = [pscustomobject]@{
            Schema = 1; Address = $config.Address; Port = $config.Port; StreamName = $config.StreamName
            Status = 'PendingReboot'; InstallBoot = $boot; Slot = -1
        }
        try {
            Write-AudioJson $settingsPath $pending
            Set-StartupAction 'Resume'
            # Only the official installer is elevated, never the downloaded scripts.
            $process = Start-Process -FilePath $installer -ArgumentList '-h -i' -Verb RunAs -WindowStyle Hidden -Wait -PassThru
            $evidence = Get-VoicemeeterInstallEvidence
            $pending.Status = Get-VoicemeeterInstallResult $process.ExitCode $evidence
            $pending | Add-Member -NotePropertyName InstallerExitCode -NotePropertyValue $process.ExitCode -Force
            Write-AudioJson $settingsPath $pending
            Write-Output "Installer returned $($process.ExitCode); application and signed VAIO driver registration verified."
        } catch {
            $failure = $_
            try { Set-StartupValue $previousStartup }
            catch { Write-Warning "Installer startup recovery failed: $($_.Exception.Message)" }
            $pending.Status = 'InstallFailed'
            try { Write-AudioJson $settingsPath $pending }
            catch { Write-Warning "Could not save installation failure: $($_.Exception.Message)" }
            throw $failure
        }
        try { Protect-PendingRebootOutput }
        catch { Write-Warning "Playback endpoint cleanup deferred: $($_.Exception.Message)" }
        Write-Output 'Installation completed. Restart Windows when convenient; configuration resumes at sign-in. No restart was initiated.'
        exit 3010
    }

    $evidence = Get-VoicemeeterInstallEvidence $directory
    if (-not $evidence.Ready) { throw ('Voicemeeter driver is not ready: ' + ($evidence.Issues -join '; ') + '. Restart Windows after installation.') }
    $remote = Connect-Remote $directory -StartIfNeeded
    Save-OriginalMixerState $remote $config
    Ensure-DriverVolumeControl -Directory $directory
    $remote = Update-NativePlaybackOptions $remote $directory $config
    $target = Get-VoicemeeterEndpoint @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender())
    $extraEndpoints = @(Get-VoicemeeterExtraEndpoints @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender()) $target)
    Save-ExtraEndpointBackup $extraEndpoints
    $transaction = Join-Path $stateRoot ('rollback-' + [Guid]::NewGuid().ToString('N') + '.xml')
    Save-VoicemeeterXml $remote $transaction
    $beforeDefaults = @(Get-DefaultEndpoints)
    $beforeStartup = Get-StartupValue
    $ownedSlot = -1
    if ($settings -and $settings.Status -eq 'Ready' -and $settings.Slot -ge 0 -and $settings.Slot -lt 4) {
        $prefix = "vban.outstream[$($settings.Slot)]"
        $null = $remote.Dirty()
        if ($remote.GetString("$prefix.name") -ceq $settings.StreamName -and
            $remote.GetString("$prefix.ip") -ceq $settings.Address -and
            $remote.GetFloat("$prefix.port") -eq $settings.Port) { $ownedSlot = $settings.Slot }
    }
    $slot = Get-DesktopStreamSlot $remote $config $ownedSlot
    $beforeParameters = Get-DesktopAudioSnapshot $remote $config $slot
    $desktopProfile = Join-Path $stateRoot 'desktop.xml'
    $oldProfile = if (Test-Path -LiteralPath $desktopProfile) { [IO.File]::ReadAllBytes($desktopProfile) } else { $null }
    $profileCommitted = $false
    try {
        Set-DesktopAudioPlan $remote $config $slot
        $runtimePolicyBackup = Enable-BackgroundPlayback $directory
        foreach ($role in 0..2) { [LanAudioBridge.WindowsAudio.Endpoints]::SetDefault($target.Id, $role) }
        foreach ($role in 0..2) {
            if ([LanAudioBridge.WindowsAudio.Endpoints]::GetDefault($role) -cne $target.Id) { throw 'Windows did not accept the playback device change.' }
        }
        Set-EndpointVisibilityState $extraEndpoints $false
        $newProfile = Join-Path $stateRoot ('desktop-' + [Guid]::NewGuid().ToString('N') + '.xml')
        Save-VoicemeeterXml $remote $newProfile
        Move-Item -LiteralPath $newProfile -Destination $desktopProfile -Force
        $profileCommitted = $true
        $ready = [pscustomobject]@{
            Schema = 1; Address = $config.Address; Port = $config.Port; StreamName = $config.StreamName
            Status = 'Ready'; InstallBoot = $null; Slot = $slot
        }
        Set-StartupAction 'Start'
        Write-AudioJson $settingsPath $ready
    } catch {
        $failure = $_
        # Independent rollback steps: an unplugged endpoint must not prevent
        # restoring the startup profile or the startup registry entry.
        try { Set-EndpointVisibilityState $extraEndpoints $true }
        catch { Write-Warning "Playback endpoint rollback failed: $($_.Exception.Message)" }
        try { Restore-VoicemeeterXml $remote $transaction $beforeParameters }
        catch { Write-Warning "Mixer rollback failed: $($_.Exception.Message). Backup: $transaction" }
        try { Restore-DefaultEndpoints $beforeDefaults }
        catch { Write-Warning "Playback rollback failed: $($_.Exception.Message)" }
        try { Set-StartupValue $beforeStartup }
        catch { Write-Warning "Startup rollback failed: $($_.Exception.Message)" }
        if ($runtimePolicyBackup -and $runtimePolicyBackup.Changed) {
            try { $null = Restore-VoicemeeterRuntimePowerPolicy -BackupPath $runtimePolicyBackup.Path }
            catch { Write-Warning "Background process policy rollback failed: $($_.Exception.Message)" }
        }
        try {
            if ($profileCommitted) {
                if ($null -ne $oldProfile) { [IO.File]::WriteAllBytes($desktopProfile, [byte[]]$oldProfile) }
                else { Remove-Item -LiteralPath $desktopProfile }
            }
        } catch { Write-Warning "Startup profile rollback failed: $($_.Exception.Message). Backup: $transaction" }
        throw $failure
    }
    Write-Output "Configured: $($target.Name) -> $($config.Address):$($config.Port), stream $($config.StreamName), 48000 Hz / stereo / PCM16."
    $remote.SetFloat('Command.Show', 0)
    try {
        $route = Test-NetConnection -ComputerName $config.Address -DiagnoseRouting -InformationLevel Detailed -WarningAction SilentlyContinue
        $sourceAddress = $route.SelectedSourceAddress
        if ($sourceAddress -and $sourceAddress.PSObject.Properties['IPAddress']) { $sourceAddress = $sourceAddress.IPAddress }
        Write-Output "Docker must enable ENABLE_DESKTOP=true and allow VBAN_SOURCE_IP=$sourceAddress."
    } catch { Write-Output 'Docker must enable ENABLE_DESKTOP=true and allow this PC LAN IPv4 in VBAN_SOURCE_IP.' }
    Write-Output 'Local settings were read back successfully. UDP delivery and sound at the receiver require a playback test.'
    Write-Output "Backup and logs: $stateRoot"
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    try { if ($remote) { $remote.Dispose() } }
    catch { Write-Warning "Remote API cleanup failed: $($_.Exception.Message)" }
    try { if ($transcribing) { Stop-Transcript | Out-Null } }
    finally {
        if ($lockHeld) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}
