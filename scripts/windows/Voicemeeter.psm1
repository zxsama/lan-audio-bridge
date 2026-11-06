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
    $found = @($Endpoints | Where-Object {
        $_.Active -and $_.Name -match '^Voicemeeter Input(?:\s*\(VB-Audio Voicemeeter VAIO\))?$'
    })
    if ($found.Count -ne 1) { throw 'Expected one active Voicemeeter Input playback endpoint. Restart Windows after installation.' }
    return $found[0]
}

Export-ModuleMember -Function *-*
