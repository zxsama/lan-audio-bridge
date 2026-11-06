# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
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
    foreach ($relative in @('windows-audio.ps1', 'windows\Voicemeeter.psm1', 'windows\AudioInterop.cs')) {
        $source = Join-Path $PSScriptRoot $relative
        $destination = Join-Path $programRoot $relative
        if ([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
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
    param([string]$Directory, [switch]$StartIfNeeded)
    $connection = New-Object LanAudioBridge.WindowsAudio.VoicemeeterRemote((Join-Path $Directory 'VoicemeeterRemote64.dll'))
    try {
        $login = $connection.Login()
        if ($login -eq 1 -and $StartIfNeeded) {
            $parameters = @{}
            $profile = Join-Path $stateRoot 'desktop.xml'
            if (Test-Path -LiteralPath $profile) { $parameters.ArgumentList = '-l"' + $profile + '"' }
            Start-Process -FilePath (Join-Path $Directory 'voicemeeter.exe') -WindowStyle Hidden @parameters | Out-Null
        }
        Wait-Voicemeeter $connection
        if ($connection.Type() -ne 1) { throw 'Voicemeeter Banana/Potato is running. This script configures Standard only.' }
        return $connection
    } catch { $connection.Dispose(); throw }
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
        $remote = Connect-Remote $directory -StartIfNeeded
        Write-Output 'Voicemeeter Standard is running.'
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
    $target = Get-VoicemeeterEndpoint @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender())
    $extraEndpoints = @(Get-VoicemeeterExtraEndpoints @([LanAudioBridge.WindowsAudio.Endpoints]::ListRender()) $target)
    Save-ExtraEndpointBackup $extraEndpoints
    $transaction = Join-Path $stateRoot ('rollback-' + [Guid]::NewGuid().ToString('N') + '.xml')
    Save-VoicemeeterXml $remote $transaction
    $originalXml = Join-Path $stateRoot 'original.xml'
    $newOriginalXml = -not (Test-Path -LiteralPath $originalXml)
    if ($newOriginalXml) { Copy-Item -LiteralPath $transaction -Destination $originalXml }
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
    if ($newOriginalXml) { Write-AudioJson (Join-Path $stateRoot 'original-parameters.json') $beforeParameters }
    $desktopProfile = Join-Path $stateRoot 'desktop.xml'
    $oldProfile = if (Test-Path -LiteralPath $desktopProfile) { [IO.File]::ReadAllBytes($desktopProfile) } else { $null }
    $profileCommitted = $false
    try {
        Set-DesktopAudioPlan $remote $config $slot
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
        try {
            if ($profileCommitted) {
                if ($null -ne $oldProfile) { [IO.File]::WriteAllBytes($desktopProfile, [byte[]]$oldProfile) }
                else { Remove-Item -LiteralPath $desktopProfile }
            }
        } catch { Write-Warning "Startup profile rollback failed: $($_.Exception.Message). Backup: $transaction" }
        throw $failure
    }
    Write-Output "Configured: $($target.Name) -> $($config.Address):$($config.Port), stream $($config.StreamName), 48000 Hz / stereo / PCM16."
    try {
        $route = Test-NetConnection -ComputerName $config.Address -DiagnoseRouting -InformationLevel Detailed -WarningAction SilentlyContinue
        Write-Output "Docker must enable ENABLE_DESKTOP=true and allow VBAN_SOURCE_IP=$($route.SelectedSourceAddress)."
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
