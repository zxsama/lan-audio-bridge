# Run with Windows PowerShell 5.1 or PowerShell 7. No Pester or audio device required.
[CmdletBinding()]
param([string]$OutputDirectory)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'scripts\windows\Voicemeeter.psm1') -Force
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'test-results\windows-audio' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$scratch = Join-Path $OutputDirectory ('unit-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
$results = New-Object 'Collections.Generic.List[object]'

if (-not ('DesktopAudioTestRemote' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
public sealed class DesktopAudioTestRemote {
    public readonly Dictionary<string, float> Floats = new Dictionary<string, float>();
    public readonly Dictionary<string, string> Strings = new Dictionary<string, string>();
    public readonly List<string> Writes = new List<string>();
    public readonly Dictionary<string, float> LoadFloats = new Dictionary<string, float>();
    public readonly Dictionary<string, string> LoadStrings = new Dictionary<string, string>();
    public int LoadDelayDirtyReads = 0;
    public int DirtyReadsAfterLoad = 0;
    public bool NeverCompleteLoad = false;
    private bool loadPending = false;
    public int MixerType = 1;
    public string IgnoreWrite = null;
    public string FailWrite = null;
    public string FailRead = null;
    public string SaveContent = "<Voicemeeter><VBAN /></Voicemeeter>";
    public bool SkipSave = false;
    public int Type() { return MixerType; }
    public int Dirty() {
        if (FailRead == "Dirty") throw new InvalidOperationException("Read API failed");
        if (loadPending) {
            DirtyReadsAfterLoad++;
            if (!NeverCompleteLoad && DirtyReadsAfterLoad > LoadDelayDirtyReads) {
                foreach (KeyValuePair<string, float> item in LoadFloats) Floats[item.Key] = item.Value;
                foreach (KeyValuePair<string, string> item in LoadStrings) Strings[item.Key] = item.Value;
                loadPending = false;
            }
        }
        return 0;
    }
    public float GetFloat(string name) {
        if (FailRead == name) throw new InvalidOperationException("Read API failed");
        float value; return Floats.TryGetValue(name, out value) ? value : 0;
    }
    public string GetString(string name) {
        if (FailRead == name) throw new InvalidOperationException("Read API failed");
        string value; return Strings.TryGetValue(name, out value) ? value : "";
    }
    public void SetFloat(string name, float value) {
        if (FailWrite == name) throw new InvalidOperationException("Write API failed");
        Writes.Add(name + "=" + value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (IgnoreWrite != name) Floats[name] = value;
    }
    public void SetString(string name, string value) {
        if (FailWrite == name) throw new InvalidOperationException("Write API failed");
        Writes.Add(name + "=" + value);
        if (IgnoreWrite != name) Strings[name] = value;
        if (name == "Command.Save" && !SkipSave) File.WriteAllText(value, SaveContent);
        if (name == "Command.Load") { loadPending = true; DirtyReadsAfterLoad = 0; }
    }
}
public sealed class DesktopAudioTestEndpoint {
    public string Id;
    public bool Active = true;
    public int State = 1;
    public string Name = "";
    public string WaveInterface = "";
    public string ParentDevice = "";
}
public static class DesktopAudioTestEndpoints {
    public static readonly string[] Defaults = new string[] { "speaker0", "speaker1", "speaker2" };
    public static readonly List<string> VisibilityWrites = new List<string>();
    public static string FailVisibilityId = null;
    public static string IgnoreVisibilityId = null;
    public static DesktopAudioTestEndpoint[] Render = new DesktopAudioTestEndpoint[] {
        new DesktopAudioTestEndpoint { Id = "speaker0" },
        new DesktopAudioTestEndpoint { Id = "speaker1" },
        new DesktopAudioTestEndpoint { Id = "speaker2" },
        new DesktopAudioTestEndpoint { Id = "virtual" }
    };
    public static string GetDefault(int role) { return Defaults[role]; }
    public static void SetDefault(string id, int role) { Defaults[role] = id; }
    public static object[] ListRender() { return Render; }
    public static uint GetState(string id) {
        foreach (DesktopAudioTestEndpoint item in Render) { if (item.Id == id) return (uint)item.State; }
        throw new InvalidOperationException("Unknown fake endpoint");
    }
    public static void SetVisibility(string id, bool visible) {
        VisibilityWrites.Add(id + "=" + visible);
        if (id == FailVisibilityId) throw new InvalidOperationException("Injected visibility failure");
        foreach (DesktopAudioTestEndpoint item in Render) {
            if (item.Id == id && id != IgnoreVisibilityId) { item.Active = visible; item.State = visible ? 1 : 2; }
        }
    }
}
'@
}

function Assert-True { param([bool]$Condition, [string]$Message = 'Assertion failed'); if (-not $Condition) { throw $Message } }
function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'Values differ')
    if ($Actual -cne $Expected) { throw "$Message. Expected [$Expected], actual [$Actual]." }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_ }
    if (-not $caught) { throw 'Expected failure, but operation succeeded.' }
    if ($Pattern -and $caught.Exception.Message -notmatch $Pattern) { throw "Unexpected failure: $($caught.Exception.Message)" }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body | Out-Null
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = $null; Milliseconds = $timer.ElapsedMilliseconds })
        Write-Host "PASS $Name"
    } catch {
        $results.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message; Milliseconds = $timer.ElapsedMilliseconds })
        Write-Host "FAIL $Name : $($_.Exception.Message)"
    }
}

$config = New-DesktopAudioConfig '192.0.2.20'
Test-Case 'IPv4 and default stream values survive validation' {
    Assert-Equal $config.Address '192.0.2.20'
    Assert-Equal $config.Port 6980
    Assert-Equal $config.StreamName 'Windows'
}
Test-Case 'IPv4 rejects abbreviated, noncanonical, loopback and multicast inputs' {
    foreach ($address in @('', 'localhost', '::1', '192.168.001.2', '192.168.1', '0.0.0.0', '127.0.0.1', '224.1.2.3', '255.255.255.255', '192.0.2.256', ' 192.0.2.20')) {
        Assert-Throws { New-DesktopAudioConfig $address } 'IPv4'
    }
}
Test-Case 'Port accepts both boundaries and rejects outside the range' {
    foreach ($port in @(1024, 65535)) { Assert-Equal (New-DesktopAudioConfig '192.0.2.20' $port).Port $port }
    foreach ($port in @(0, 1023, 65536, -1)) { Assert-Throws { New-DesktopAudioConfig '192.0.2.20' $port } 'Port' }
}
Test-Case 'Stream name validates byte-compatible length and character set' {
    Assert-Equal (New-DesktopAudioConfig '192.0.2.20' 6980 'Abcd_012345678-z').StreamName 'Abcd_012345678-z'
    foreach ($name in @('', '12345678901234567', 'a b', 'x.y', ('a' + [char]0x4e2d), "x`ny", 'x;y')) {
        Assert-Throws { New-DesktopAudioConfig '192.0.2.20' 6980 $name } 'Stream name'
    }
}
Test-Case 'Standard routing isolates microphones and sends stereo PCM16 BUS B' {
    $plan = Get-DesktopAudioPlan $config 2
    $expected = @{
        'Strip[0].B1' = 0; 'Strip[1].B1' = 0; 'Strip[2].A1' = 0; 'Strip[2].B1' = 1
        'Strip[2].Mute' = 0; 'Strip[2].Gain' = 0; 'Bus[1].Mute' = 0; 'Bus[1].Gain' = 0
        'Option.sr' = 48000; 'vban.outstream[2].name' = 'Windows'; 'vban.outstream[2].ip' = '192.0.2.20'
        'vban.outstream[2].port' = 6980; 'vban.outstream[2].sr' = 48000; 'vban.outstream[2].channel' = 2
        'vban.outstream[2].bit' = 1; 'vban.outstream[2].route' = 1
    }
    Assert-Equal $plan.Count $expected.Count
    foreach ($key in $expected.Keys) { Assert-Equal $plan[$key] $expected[$key] $key }
    foreach ($slot in @(-1, 4)) { Assert-Throws { Get-DesktopAudioPlan $config $slot } 'slot' }
}
Test-Case 'Endpoint selection excludes Aux, output and inactive endpoints' {
    $endpoints = @(
        [pscustomobject]@{ Id = 'aux'; Active = $true; Name = 'Voicemeeter Aux Input (VB-Audio Voicemeeter AUX VAIO)' }
        [pscustomobject]@{ Id = 'output'; Active = $true; Name = 'Voicemeeter Output (VB-Audio Voicemeeter VAIO)' }
        [pscustomobject]@{ Id = 'old'; Active = $false; Name = 'Voicemeeter Input' }
        [pscustomobject]@{ Id = 'main'; Active = $true; Name = 'Voicemeeter Input (VB-Audio Voicemeeter VAIO)' }
    )
    Assert-Equal (Get-VoicemeeterEndpoint $endpoints).Id 'main'
    Assert-Throws { Get-VoicemeeterEndpoint $endpoints[0..2] } 'one active'
    Assert-Throws { Get-VoicemeeterEndpoint @($endpoints[3], $endpoints[3]) } 'one active'
}
function New-TestEndpoint {
    param([string]$Id, [int]$Pin = 6, [string]$Parent = 'ROOT\MEDIA\0000', [int]$State = 1)
    $endpoint = New-Object DesktopAudioTestEndpoint
    $endpoint.Id = $Id
    $endpoint.State = $State
    $endpoint.Active = $State -eq 1
    $endpoint.Name = 'Renamed virtual playback'
    $endpoint.ParentDevice = $Parent
    $endpoint.WaveInterface = '\\?\root#media#0000#{test}\vbvoicemeetervaio2023_out' + $Pin + '_wave_0'
    return $endpoint
}
Test-Case 'Primary virtual playback selection follows exact VAIO pin despite renamed display names' {
    $endpoints = @(1..8 | ForEach-Object { New-TestEndpoint "pin$_" $_ })
    $endpoints[0].Name = 'Voicemeeter Input'
    Assert-Equal (Get-VoicemeeterEndpoint $endpoints).Id 'pin6'
    $endpoints[5].WaveInterface = $endpoints[5].WaveInterface.Replace('out6_', 'out16_')
    Assert-Throws { Get-VoicemeeterEndpoint $endpoints } 'one active|primary|VAIO'
}
Test-Case 'Virtual playback selection rejects missing parent inactive pin and ambiguous primary pins' {
    Assert-Throws { Get-VoicemeeterEndpoint @(New-TestEndpoint 'missing-parent' 6 '') } 'one active|primary|VAIO'
    Assert-Throws { Get-VoicemeeterEndpoint @(New-TestEndpoint 'disabled' 6 'ROOT\MEDIA\0000' 2) } 'one active|primary|VAIO'
    Assert-Throws { Get-VoicemeeterEndpoint @((New-TestEndpoint 'primary-a'), (New-TestEndpoint 'primary-b')) } 'one active|primary|VAIO'
}
Test-Case 'Extra playback selection contains only the seven active pins on the verified parent' {
    $endpoints = @(1..8 | ForEach-Object { New-TestEndpoint "{0.0.0.00000000}.pin$_" $_ })
    $endpoints += New-TestEndpoint '{0.0.0.00000000}.other-hardware' 1 'USB\AUDIO\OTHER'
    $endpoints += New-TestEndpoint '{0.0.0.00000000}.disconnected' 2 'ROOT\MEDIA\0000' 8
    $endpoints += New-TestEndpoint '{0.0.0.00000000}.disabled' 3 'ROOT\MEDIA\0000' 2
    $endpoints += New-TestEndpoint '{0.0.0.00000000}.unknown-pin' 16
    $endpoints += New-TestEndpoint '{0.0.0.00000000}.capture-wave' 1
    $endpoints[-1].WaveInterface = $endpoints[-1].WaveInterface.Replace('_out1_', '_in1_')
    $endpoints += New-TestEndpoint '{0.0.1.00000000}.capture-id' 1
    $target = Get-VoicemeeterEndpoint $endpoints
    $extra = @(Get-VoicemeeterExtraEndpoints $endpoints $target)
    Assert-Equal $extra.Count 7
    Assert-Equal (($extra.Id | Sort-Object) -join ',') ((@(1,2,3,4,5,7,8) | ForEach-Object { "{0.0.0.00000000}.pin$_" }) -join ',')
}
Test-Case 'Unverified legacy endpoint identity never permits hiding additional outputs' {
    $target = [pscustomobject]@{ Id = 'legacy'; Active = $true; Name = 'Voicemeeter Input' }
    Assert-Equal @(Get-VoicemeeterExtraEndpoints @((New-TestEndpoint 'extra' 1)) $target).Count 0
}
Test-Case 'Installer result accepts 0 and 1 only with complete installation evidence' {
    foreach ($code in @(0, 1)) {
        Assert-Equal (Get-VoicemeeterInstallResult $code ([pscustomobject]@{ Complete = $true; Issues = @() })) 'PendingReboot'
        Assert-Throws { Get-VoicemeeterInstallResult $code ([pscustomobject]@{ Complete = $false; Issues = @('Driver missing') }) } 'Driver missing|evidence|incomplete'
    }
    foreach ($code in @(-1, 2, 7, 3010)) {
        Assert-Throws { Get-VoicemeeterInstallResult $code ([pscustomobject]@{ Complete = $true; Issues = @() }) } 'exit|code|result'
    }
}
Test-Case 'Mixer snapshot preserves all 18 current values including stream and global enable flags' {
    $remote = New-Object DesktopAudioTestRemote
    $plan = Get-DesktopAudioPlan $config 2
    foreach ($name in $plan.Keys) {
        if ($plan[$name] -is [string]) { $remote.Strings[$name] = 'original-' + $name }
        else { $remote.Floats[$name] = 42 }
    }
    $remote.Floats['vban.Enable'] = 1
    $remote.Floats['vban.outstream[2].on'] = 1
    $snapshot = Get-DesktopAudioSnapshot $remote $config 2
    Assert-Equal $snapshot.Count 18
    foreach ($name in $plan.Keys) {
        $expected = if ($plan[$name] -is [string]) { 'original-' + $name } else { 42 }
        Assert-Equal $snapshot[$name] $expected $name
    }
    Assert-Equal $snapshot['vban.Enable'] 1
    Assert-Equal $snapshot['vban.outstream[2].on'] 1
    Assert-Equal $remote.Writes.Count 0
}
Test-Case 'XML restore tolerates stale successful Dirty reads and verifies every saved field before returning' {
    $remote = New-Object DesktopAudioTestRemote
    $remote.LoadDelayDirtyReads = 3
    $expected = Get-DesktopAudioPlan $config 2
    $expected['vban.Enable'] = 1
    $expected['vban.outstream[2].on'] = 1
    foreach ($name in $expected.Keys) {
        if ($expected[$name] -is [string]) { $remote.LoadStrings[$name] = $expected[$name] }
        else { $remote.LoadFloats[$name] = $expected[$name] }
    }
    Restore-VoicemeeterXml $remote 'X:\Fake\original.xml' $expected -TimeoutSeconds 2
    Assert-Equal $remote.DirtyReadsAfterLoad 4
    Assert-True (Test-DesktopAudioPlan $remote $expected)
    Assert-Equal $remote.Writes.Count 1
    Assert-Equal $remote.Writes[0] 'Command.Load=X:\Fake\original.xml'
}
Test-Case 'XML restore reports failure when saved parameters never become observable' {
    $remote = New-Object DesktopAudioTestRemote
    $remote.NeverCompleteLoad = $true
    Assert-Throws { Restore-VoicemeeterXml $remote 'X:\Fake\original.xml' ([ordered]@{ 'vban.Enable' = 1 }) -TimeoutSeconds 0 } 'did not match.*backup'
    Assert-Equal $remote.DirtyReadsAfterLoad 1
    Assert-Equal $remote.Writes.Count 1
}
Test-Case 'Slot selection preserves enabled streams and fails safely when full' {
    $remote = New-Object DesktopAudioTestRemote
    $remote.Floats['vban.outstream[0].on'] = 1
    Assert-Equal (Get-DesktopStreamSlot $remote $config) 1
    foreach ($slot in 0..3) { $remote.Floats["vban.outstream[$slot].on"] = 1 }
    Assert-Throws { Get-DesktopStreamSlot $remote $config } 'in use'
    Assert-Equal $remote.Writes.Count 0
    Assert-Equal (Get-DesktopStreamSlot $remote $config 2) 2
}
Test-Case 'Apply verifies complete readback before enabling the stream' {
    $remote = New-Object DesktopAudioTestRemote
    Set-DesktopAudioPlan $remote $config 1 -TimeoutSeconds 0
    Assert-True (Test-DesktopAudioPlan $remote (Get-DesktopAudioPlan $config 1))
    Assert-Equal $remote.Floats['vban.Enable'] 1
    Assert-Equal $remote.Writes[0] 'vban.outstream[1].on=0'
    Assert-Equal $remote.Writes[$remote.Writes.Count - 1] 'vban.outstream[1].on=1'
}
Test-Case 'Repeated apply has the same final state and leaves other slots intact' {
    $remote = New-Object DesktopAudioTestRemote
    $remote.Floats['vban.outstream[0].on'] = 1
    $remote.Strings['vban.outstream[0].name'] = 'Existing'
    Set-DesktopAudioPlan $remote $config 1 -TimeoutSeconds 0
    $first = ($remote.Floats.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
    Set-DesktopAudioPlan $remote $config 1 -TimeoutSeconds 0
    $second = ($remote.Floats.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
    Assert-Equal $second $first
    Assert-Equal $remote.Floats['vban.outstream[0].on'] 1
    Assert-Equal $remote.Strings['vban.outstream[0].name'] 'Existing'
}
Test-Case 'Wrong mixer edition is rejected before any writes' {
    foreach ($edition in @(0, 2, 3)) {
        $remote = New-Object DesktopAudioTestRemote
        $remote.MixerType = $edition
        Assert-Throws { Set-DesktopAudioPlan $remote $config 0 -TimeoutSeconds 0 } 'Standard'
        Assert-Equal $remote.Writes.Count 0
    }
}
Test-Case 'Ignored numeric and string writes cannot report success or enable output' {
    foreach ($field in @('vban.outstream[0].sr', 'vban.outstream[0].name', 'vban.Enable')) {
        $remote = New-Object DesktopAudioTestRemote
        $remote.IgnoreWrite = $field
        Assert-Throws { Set-DesktopAudioPlan $remote $config 0 -TimeoutSeconds 0 } 'did not match'
        Assert-Equal $remote.Floats['vban.outstream[0].on'] 0
        Assert-True (-not $remote.Writes.Contains('vban.outstream[0].on=1'))
    }
}
Test-Case 'Failed API writes and reads cannot report success' {
    $remote = New-Object DesktopAudioTestRemote
    $remote.FailWrite = 'vban.outstream[0].port'
    Assert-Throws { Set-DesktopAudioPlan $remote $config 0 -TimeoutSeconds 0 } 'Write API failed'
    Assert-Equal $remote.Floats['vban.outstream[0].on'] 0
    $remote = New-Object DesktopAudioTestRemote
    $remote.FailRead = 'Dirty'
    Assert-Throws { Set-DesktopAudioPlan $remote $config 0 -TimeoutSeconds 0 } 'did not match'
    Assert-Equal $remote.Floats['vban.outstream[0].on'] 0
}
Test-Case 'Readback detects stream name case mismatch' {
    $remote = New-Object DesktopAudioTestRemote
    Set-DesktopAudioPlan $remote $config 0 -TimeoutSeconds 0
    $remote.Strings['vban.outstream[0].name'] = 'windows'
    Assert-True (-not (Test-DesktopAudioPlan $remote (Get-DesktopAudioPlan $config 0)))
}
Test-Case 'XML backup round-trips a path containing spaces' {
    $remote = New-Object DesktopAudioTestRemote
    $path = Join-Path $scratch 'saved profile.xml'
    Save-VoicemeeterXml $remote $path
    $xml = New-Object Xml.XmlDocument
    $xml.Load($path)
    Assert-Equal $xml.DocumentElement.Name 'Voicemeeter'
}
Test-Case 'XML backup rejects missing or malformed saved content' {
    $remote = New-Object DesktopAudioTestRemote
    $remote.SkipSave = $true
    Assert-Throws { Save-VoicemeeterXml $remote (Join-Path $scratch 'missing.xml') } 'readable XML'
    $remote.SkipSave = $false
    $remote.SaveContent = '<unfinished'
    Assert-Throws { Save-VoicemeeterXml $remote (Join-Path $scratch 'malformed.xml') } 'readable XML'
}
Test-Case 'JSON persistence retains exact settings and leaves no temporary file' {
    $path = Join-Path $scratch 'settings.json'
    Write-AudioJson $path $config
    $saved = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-Equal $saved.Address $config.Address
    Assert-Equal $saved.Port $config.Port
    Assert-Equal $saved.StreamName $config.StreamName
    Assert-True (-not (Test-Path -LiteralPath ($path + '.tmp')))
}
Test-Case 'Installer validation rejects untrusted bytes before execution' {
    $path = Join-Path $scratch 'not-an-installer.exe'
    [IO.File]::WriteAllText($path, 'not an installer')
    Assert-Throws { Assert-VoicemeeterInstaller $path } 'SHA256'
}

# Parse, then invoke only isolated function/transaction bodies with fake endpoints.
# The production entry point is never invoked with Setup/Resume/Start/Restore.
$parseTokens = $null
$parseErrors = $null
$entryPath = Join-Path $repo 'scripts\windows-audio.ps1'
$entryAst = [Management.Automation.Language.Parser]::ParseFile($entryPath, [ref]$parseTokens, [ref]$parseErrors)
Test-Case 'Entry script parses without errors' { Assert-Equal @($parseErrors).Count 0 }
function Get-IsolatedFunction {
    param([string]$Name)
    $node = $entryAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $Name }, $true)
    if (-not $node) {
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\windows\Voicemeeter.psm1'), [ref]$null, [ref]$null)
        $node = $moduleAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $Name }, $true)
    }
    if (-not $node) { throw "Missing production function: $Name" }
    return [scriptblock]::Create($node.Extent.Text.Replace('[LanAudioBridge.WindowsAudio.Endpoints]', '[DesktopAudioTestEndpoints]'))
}
Test-Case 'Installation evidence requires the supported signed files driver registration service and device health' {
    . (Get-IsolatedFunction 'Get-VoicemeeterInstallEvidence')
    $evidenceCase = 'Valid'
    function Test-Path {
        param([string]$LiteralPath, [string]$PathType)
        return -not (($evidenceCase -eq 'MissingFile' -and $LiteralPath -like '*voicemeeter.exe') -or
            ($evidenceCase -eq 'MissingDriverBinary' -and $LiteralPath -like '*.sys'))
    }
    function Get-Item {
        param([string]$LiteralPath)
        $private = if ($evidenceCase -eq 'WrongFileVersion') { 9 } else { 0 }
        [pscustomobject]@{ VersionInfo = [pscustomobject]@{ FileMajorPart = 1; FileMinorPart = 1; FileBuildPart = 3; FilePrivatePart = $private } }
    }
    function Get-AuthenticodeSignature {
        param([string]$LiteralPath)
        $certificate = New-Object PSObject
        $certificate | Add-Member ScriptMethod GetNameInfo { param($Kind, $Issuer) 'BUREL VINCENT Entrepreneur individuel' }
        [pscustomobject]@{ Status = $(if ($evidenceCase -eq 'InvalidSignature') { 'NotTrusted' } else { 'Valid' }); SignerCertificate = $certificate }
    }
    function Get-CimInstance {
        param([string]$ClassName, [string]$Filter)
        switch ($ClassName) {
            'Win32_PnPSignedDriver' {
                if ($evidenceCase -eq 'MissingDriver') { return }
                $driver = [pscustomobject]@{
                    IsSigned = $evidenceCase -ne 'UnsignedDriver'
                    Signer = $(if ($evidenceCase -eq 'WrongDriverSigner') { 'Other signer' } else { 'Microsoft Windows Hardware Compatibility Publisher' })
                    DriverVersion = $(if ($evidenceCase -eq 'WrongDriverVersion') { '0.0.0.0' } else { '3.4.1.9' })
                    InfName = 'oem77.inf'; DeviceID = 'ROOT\MEDIA\0000'
                }
                if ($evidenceCase -eq 'DuplicateDriver') { $driver }
                return $driver
            }
            'Win32_PnPEntity' {
                if ($evidenceCase -eq 'MissingDevice') { return }
                $problem = if ($evidenceCase -eq 'RebootRequired') { 14 } elseif ($evidenceCase -eq 'DeviceProblem') { 22 } else { 0 }
                return [pscustomobject]@{ PNPDeviceID = 'ROOT\MEDIA\0000'; ConfigManagerErrorCode = $problem }
            }
            'Win32_SystemDriver' {
                if ($evidenceCase -eq 'MissingService') { return }
                return [pscustomobject]@{ PathName = 'C:\Fake\driver.sys'; State = $(if ($evidenceCase -eq 'StoppedService') { 'Stopped' } else { 'Running' }) }
            }
            default { throw "Unexpected read-only system query: $ClassName" }
        }
    }
    foreach ($evidenceCase in @('Valid', 'RebootRequired', 'StoppedService', 'MissingFile', 'WrongFileVersion', 'InvalidSignature',
        'MissingDriver', 'UnsignedDriver', 'WrongDriverSigner', 'WrongDriverVersion', 'DuplicateDriver', 'MissingDevice',
        'DeviceProblem', 'MissingService', 'MissingDriverBinary')) {
        $evidence = Get-VoicemeeterInstallEvidence 'C:\Fake\Voicemeeter'
        Assert-Equal $evidence.Complete ($evidenceCase -in @('Valid', 'RebootRequired', 'StoppedService')) $evidenceCase
        Assert-Equal $evidence.Ready ($evidenceCase -eq 'Valid') $evidenceCase
        if (-not $evidence.Complete) { Assert-True ($evidence.Issues.Count -gt 0) $evidenceCase }
    }
}
Test-Case 'Visibility changes verify state and preserve endpoints outside the explicit snapshot' {
    . (Get-IsolatedFunction 'Set-EndpointVisibilityState')
    $before = [DesktopAudioTestEndpoints]::Render
    try {
        [DesktopAudioTestEndpoints]::Render = @((New-TestEndpoint 'primary'), (New-TestEndpoint 'extra' 1), (New-TestEndpoint 'disabled' 2 'ROOT\MEDIA\0000' 2))
        [DesktopAudioTestEndpoints]::VisibilityWrites.Clear()
        $snapshot = @([pscustomobject]@{ Id = 'extra' })
        Set-EndpointVisibilityState $snapshot $false
        Assert-Equal ([DesktopAudioTestEndpoints]::GetState('extra')) 2
        Assert-Equal ([DesktopAudioTestEndpoints]::GetState('primary')) 1
        Assert-Equal ([DesktopAudioTestEndpoints]::GetState('disabled')) 2
        Set-EndpointVisibilityState $snapshot $true
        Assert-Equal ([DesktopAudioTestEndpoints]::GetState('extra')) 1
        Assert-Equal ([DesktopAudioTestEndpoints]::VisibilityWrites -join ',') 'extra=False,extra=True'
        [DesktopAudioTestEndpoints]::IgnoreVisibilityId = 'extra'
        Assert-Throws { Set-EndpointVisibilityState $snapshot $false } 'state|accept|visibility|verify'
        [DesktopAudioTestEndpoints]::IgnoreVisibilityId = $null
        [DesktopAudioTestEndpoints]::FailVisibilityId = 'extra'
        Assert-Throws { Set-EndpointVisibilityState $snapshot $false } 'visibility failure'
    } finally {
        [DesktopAudioTestEndpoints]::Render = $before
        [DesktopAudioTestEndpoints]::IgnoreVisibilityId = $null
        [DesktopAudioTestEndpoints]::FailVisibilityId = $null
    }
}
Test-Case 'Pending-reboot cleanup defers without touching devices when the primary endpoint is not active' {
    . (Get-IsolatedFunction 'Protect-PendingRebootOutput')
    function Save-ExtraEndpointBackup { throw 'Unexpected backup mutation before endpoints are ready' }
    $before = [DesktopAudioTestEndpoints]::Render
    try {
        [DesktopAudioTestEndpoints]::Render = @((New-TestEndpoint 'not-ready' 6 'ROOT\MEDIA\0000' 2))
        [DesktopAudioTestEndpoints]::VisibilityWrites.Clear()
        $output = Protect-PendingRebootOutput
        Assert-True (($output -join ' ') -match 'deferred')
        Assert-Equal ([DesktopAudioTestEndpoints]::VisibilityWrites.Count) 0
    } finally { [DesktopAudioTestEndpoints]::Render = $before }
}
foreach ($restoreScenario in @('MissingAuxiliary', 'AuxiliaryFailure')) {
    Test-Case "Restore $restoreScenario continues physical defaults and startup recovery" {
        . (Get-IsolatedFunction 'Restore-DefaultEndpoints')
        . (Get-IsolatedFunction 'Set-EndpointVisibilityState')
        $restoreNode = $entryAst.Find({ param($ast)
            $ast -is [Management.Automation.Language.IfStatementAst] -and $ast.Clauses[0].Item1.Extent.Text -eq '$Action -eq ''Restore'''
        }, $true)
        Assert-True ($null -ne $restoreNode) 'Restore branch was not found.'
        $restoreText = $restoreNode.Extent.Text.Replace('[LanAudioBridge.WindowsAudio.Endpoints]', '[DesktopAudioTestEndpoints]').Replace('exit 0', 'return')
        $isolatedRestore = [scriptblock]::Create($restoreText)
        $stateRoot = Join-Path $scratch $restoreScenario
        New-Item -ItemType Directory -Path $stateRoot | Out-Null
        $backupPath = Join-Path $stateRoot 'original.json'
        $endpointBackupPath = Join-Path $stateRoot 'endpoints-original.json'
        $settingsPath = Join-Path $stateRoot 'settings.json'
        $original = [pscustomobject]@{
            Defaults = @(0..2 | ForEach-Object { [pscustomobject]@{ Role = $_; Id = "speaker$_" } })
            Startup = [pscustomobject]@{ Exists = $true; Value = 'original startup' }
        }
        [IO.File]::WriteAllText($backupPath, ($original | ConvertTo-Json -Depth 6))
        [IO.File]::WriteAllText($endpointBackupPath, (@{ Endpoints = @(@{ Id = 'extra' }, @{ Id = 'removed' }, @{ Id = 'disconnected' }) } | ConvertTo-Json -Depth 6))
        $before = [DesktopAudioTestEndpoints]::Render
        $fakeRestore = @{ Startup = $null; Status = $null }
        function Set-StartupValue { param($Value) $fakeRestore.Startup = $Value.Value }
        function Write-AudioJson { param([string]$Path, $Value) $fakeRestore.Status = $Value.Status }
        function Connect-Remote { throw 'Unexpected mixer connection in isolated restore' }
        $settings = [pscustomobject]@{ Status = 'Ready' }
        $directory = $null
        $Action = 'Restore'
        try {
            [DesktopAudioTestEndpoints]::Render = @(
                (New-TestEndpoint 'speaker0'), (New-TestEndpoint 'speaker1'), (New-TestEndpoint 'speaker2'),
                (New-TestEndpoint 'extra' 1 'ROOT\MEDIA\0000' 2), (New-TestEndpoint 'disconnected' 2 'ROOT\MEDIA\0000' 8)
            )
            [DesktopAudioTestEndpoints]::VisibilityWrites.Clear()
            if ($restoreScenario -eq 'AuxiliaryFailure') { [DesktopAudioTestEndpoints]::FailVisibilityId = 'extra' }
            foreach ($role in 0..2) { [DesktopAudioTestEndpoints]::SetDefault('virtual', $role) }
            & $isolatedRestore
            foreach ($role in 0..2) { Assert-Equal ([DesktopAudioTestEndpoints]::GetDefault($role)) "speaker$role" }
            Assert-Equal $fakeRestore.Startup 'original startup'
            Assert-Equal $fakeRestore.Status 'Restored'
            Assert-Equal ([DesktopAudioTestEndpoints]::VisibilityWrites -join ',') 'extra=True'
        } finally {
            [DesktopAudioTestEndpoints]::Render = $before
            [DesktopAudioTestEndpoints]::FailVisibilityId = $null
        }
    }
}
Test-Case 'Default endpoint backup serializes three flat role records' {
    . (Get-IsolatedFunction 'Get-DefaultEndpoints')
    $defaults = @(Get-DefaultEndpoints)
    Assert-Equal $defaults.Count 3
    foreach ($role in 0..2) { Assert-Equal $defaults[$role].Role $role; Assert-Equal $defaults[$role].Id "speaker$role" }
    $saved = [pscustomobject]@{ Defaults = $defaults } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    Assert-Equal $saved.Defaults.Count 3
    Assert-Equal $saved.Defaults[2].Id 'speaker2'
}
Test-Case 'Startup command quotes paths and rejects overlong Run entries before writing' {
    . (Get-IsolatedFunction 'Set-StartupAction')
    $captured = @{ Value = $null; Writes = 0 }
    function Set-StartupValue { param($Value) $captured.Value = $Value; $captured.Writes++ }
    $programRoot = 'C:\Users\Test User\AppData\Local\LanAudioBridge\WindowsAudio\program'
    Set-StartupAction 'Resume'
    Assert-True $captured.Value.Exists
    Assert-True ($captured.Value.Value -match ' -File "C:\\Users\\Test User\\.*windows-audio\.ps1" -Action Resume$')
    Assert-True ($captured.Value.Value.Length -le 260)
    $programRoot = 'C:\' + ('x' * 240)
    Assert-Throws { Set-StartupAction 'Start' } 'too long'
    Assert-Equal $captured.Writes 1
}
foreach ($failureMode in @('Startup', 'Settings', 'MixerRollback', 'EndpointRollback', 'StartupRollback', 'ProfileRollback', 'FreshProfile', 'CompoundRollback')) {
    Test-Case "Configuration transaction independently recovers from $failureMode failure" {
        . (Get-IsolatedFunction 'Get-DefaultEndpoints')
        . (Get-IsolatedFunction 'Restore-DefaultEndpoints')
        . (Get-IsolatedFunction 'Set-EndpointVisibilityState')
        $transactionNode = $entryAst.Find({ param($ast)
            $ast -is [Management.Automation.Language.TryStatementAst] -and
            $ast.Body.Extent.Text -match '^\{\s*Set-DesktopAudioPlan' -and
            $ast.Body.Extent.Text -match 'Write-AudioJson'
        }, $true)
        Assert-True ($null -ne $transactionNode) 'Configuration transaction was not found.'
        $isolated = [scriptblock]::Create($transactionNode.Extent.Text.Replace('[LanAudioBridge.WindowsAudio.Endpoints]', '[DesktopAudioTestEndpoints]'))
        $stateRoot = Join-Path $scratch $failureMode
        New-Item -ItemType Directory -Path $stateRoot | Out-Null
        $settingsPath = Join-Path $stateRoot 'settings.json'
        $desktopProfile = Join-Path $stateRoot 'desktop.xml'
        $transaction = Join-Path $stateRoot 'rollback.xml'
        if ($failureMode -ne 'FreshProfile') { [IO.File]::WriteAllText($desktopProfile, '<original-desktop />') }
        [IO.File]::WriteAllText($transaction, '<transaction-backup />')
        $oldProfile = if ($failureMode -eq 'FreshProfile') { $null } else { [IO.File]::ReadAllBytes($desktopProfile) }
        $profileCommitted = $false
        $target = [pscustomobject]@{ Id = 'virtual' }
        $extraEndpoints = @([pscustomobject]@{ Id = 'extra' })
        [DesktopAudioTestEndpoints]::Render = @(
            (New-TestEndpoint 'speaker0'), (New-TestEndpoint 'speaker1'), (New-TestEndpoint 'speaker2'),
            (New-TestEndpoint 'virtual'), (New-TestEndpoint 'extra' 1)
        )
        [DesktopAudioTestEndpoints]::VisibilityWrites.Clear()
        $remote = New-Object DesktopAudioTestRemote
        if ($failureMode -in @('MixerRollback', 'CompoundRollback')) { $remote.FailWrite = 'Command.Load' }
        if ($failureMode -eq 'EndpointRollback') {
            function Restore-DefaultEndpoints { param($Defaults) throw 'Injected device unavailable' }
        }
        $slot = 0
        $beforeParameters = Get-DesktopAudioSnapshot $remote $config $slot
        foreach ($name in $beforeParameters.Keys) {
            if ($beforeParameters[$name] -is [string]) { $remote.LoadStrings[$name] = $beforeParameters[$name] }
            else { $remote.LoadFloats[$name] = $beforeParameters[$name] }
        }
        foreach ($role in 0..2) { [DesktopAudioTestEndpoints]::SetDefault("speaker$role", $role) }
        $beforeDefaults = @(Get-DefaultEndpoints)
        $beforeStartup = [pscustomobject]@{ Exists = $true; Value = 'prior command' }
        $fakeState = @{ Startup = $beforeStartup; Mode = $failureMode; ProfileLock = $null }
        function Set-StartupAction {
            param([string]$StartupAction)
            $fakeState.Startup = [pscustomobject]@{ Exists = $true; Value = $StartupAction }
            if ($fakeState.Mode -eq 'Startup') { throw 'Injected startup failure' }
            if ($fakeState.Mode -eq 'ProfileRollback') {
                $fakeState.ProfileLock = [IO.File]::Open($desktopProfile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            }
        }
        function Set-StartupValue {
            param($Value)
            if ($fakeState.Mode -eq 'StartupRollback') { throw 'Injected startup recovery failure' }
            $fakeState.Startup = $Value
        }
        function Write-AudioJson {
            param([string]$Path, $Value)
            if ($fakeState.Mode -eq 'CompoundRollback') { [DesktopAudioTestEndpoints]::FailVisibilityId = 'extra' }
            throw 'Injected settings failure'
        }
        try { Assert-Throws { . $isolated } 'Injected (startup|settings) failure' }
        finally {
            if ($fakeState.ProfileLock) { $fakeState.ProfileLock.Dispose() }
            [DesktopAudioTestEndpoints]::FailVisibilityId = $null
        }
        if ($failureMode -eq 'FreshProfile') { Assert-True (-not (Test-Path -LiteralPath $desktopProfile)) }
        elseif ($failureMode -eq 'ProfileRollback') { Assert-Equal ([IO.File]::ReadAllText($desktopProfile)) $remote.SaveContent }
        else { Assert-Equal ([IO.File]::ReadAllText($desktopProfile)) '<original-desktop />' }
        if ($failureMode -eq 'StartupRollback') { Assert-Equal $fakeState.Startup.Value 'Start' }
        else { Assert-Equal $fakeState.Startup.Value 'prior command' }
        if ($failureMode -ne 'EndpointRollback') {
            foreach ($role in 0..2) { Assert-Equal ([DesktopAudioTestEndpoints]::GetDefault($role)) "speaker$role" }
        }
        if ($failureMode -notin @('MixerRollback', 'CompoundRollback')) {
            Assert-True $remote.Writes.Contains('Command.Load=' + $transaction) 'Mixer rollback was not requested.'
        }
        Assert-True ([DesktopAudioTestEndpoints]::VisibilityWrites.Contains('extra=True')) 'Endpoint visibility rollback was not attempted.'
        if ($failureMode -ne 'CompoundRollback') { Assert-Equal ([DesktopAudioTestEndpoints]::GetState('extra')) 1 }
        Assert-True (-not (Test-Path -LiteralPath $settingsPath)) 'Failed settings must not be committed.'
    }
}

# Keep exit statements intact: run only the selected production AST in a child
# PowerShell, with every side-effecting command replaced by an in-memory fake.
function Invoke-IsolatedInstallState {
    param([string]$Scenario, [switch]$BootGuard, [switch]$Adoption, [switch]$Existing)
    $adoptText = ''
    if ($Adoption) {
        $adoptNode = $entryAst.Find({ param($ast)
            $ast -is [Management.Automation.Language.IfStatementAst] -and
            $ast.Clauses[0].Item1.Extent.Text -match "settings.Status -eq 'InstallFailed'"
        }, $true)
        Assert-True ($null -ne $adoptNode) 'Adoption state machine AST was not found.'
        $adoptText = $adoptNode.Extent.Text
    }
    if ($Existing) {
        $node = $entryAst.Find({ param($ast)
            $ast -is [Management.Automation.Language.IfStatementAst] -and
            $ast.Clauses[0].Item1.Extent.Text -eq '-not $evidence.Ready'
        }, $true)
        $adoptText = '$evidence = Get-VoicemeeterInstallEvidence $directory'
    } elseif ($BootGuard -or $Adoption) {
        $node = $entryAst.Find({ param($ast)
            $ast -is [Management.Automation.Language.IfStatementAst] -and
            $ast.Clauses[0].Item1.Extent.Text -match 'InstallBoot -eq \$boot'
        }, $true)
    } else {
        $node = $entryAst.Find({ param($ast)
            $ast -is [Management.Automation.Language.IfStatementAst] -and
            $ast.Clauses[0].Item1.Extent.Text -eq '-not $directory' -and
            $ast.Extent.Text -match 'Get-VoicemeeterInstaller'
        }, $true)
    }
    Assert-True ($null -ne $node) 'Installation state machine AST was not found.'
    $allowedCommands = @('Write-Output', 'Write-Warning', 'Get-VoicemeeterInstaller', 'Join-Path', 'Get-StartupValue',
        'Write-AudioJson', 'Set-StartupAction', 'Start-Process', 'Get-VoicemeeterDirectory', 'Set-StartupValue',
        'Get-VoicemeeterInstallEvidence', 'Get-VoicemeeterInstallResult', 'Add-Member', 'Protect-PendingRebootOutput')
    $isolatedAst = [Management.Automation.Language.Parser]::ParseInput(($adoptText + "`r`n" + $node.Extent.Text), [ref]$null, [ref]$null)
    foreach ($command in $isolatedAst.FindAll({ param($ast) $ast -is [Management.Automation.Language.CommandAst] }, $true)) {
        Assert-True ($allowedCommands -contains $command.GetCommandName()) "Unexpected installer command requires an explicit fake: $($command.GetCommandName())"
    }
    Assert-Equal @($isolatedAst.FindAll({ param($ast) $ast -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)).Count 0 'Unexpected direct API call in isolated installer'
    $childPath = Join-Path $scratch ('install-' + $Scenario + '.ps1')
    $childReport = Join-Path $scratch ('install-' + $Scenario + '.json')
    $prefix = @'
param([string]$Scenario, [string]$ReportPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$fakeState = @{ Startup = 'original startup'; Status = $null; Boot = $null; InstallerCalls = 0; Continued = $false; Error = $null; ArgumentList = $null; Verb = $null; WindowStyle = $null; Wait = $false }
$stateRoot = 'X:\FakeState'
$settingsPath = 'X:\FakeState\settings.json'
$directory = $null
$Action = 'Setup'
$config = [pscustomobject]@{ Schema = 1; Address = '192.0.2.20'; Port = 6980; StreamName = 'Windows' }
$boot = 'boot-2'
$settings = [pscustomobject]@{ Status = 'PendingReboot'; InstallBoot = 'boot-1' }
if ($Scenario -in @('SameBoot', 'SameBootCleanupFailure')) { $settings.InstallBoot = $boot }
if ($Scenario -in @('AdoptSameBoot', 'AdoptInvalid')) {
    $settings.Status = 'InstallFailed'; $settings.InstallBoot = $boot; $directory = 'X:\FakeInstalled'
}
if ($Scenario -eq 'InvalidExisting') { $directory = 'X:\FakeInstalled' }
if ($Scenario -eq 'ResumeMissing') { $Action = 'Resume' }
function Get-VoicemeeterInstaller { param([string]$CacheDirectory) return 'X:\NeverExecute\fake-installer.exe' }
function Get-StartupValue { return [pscustomobject]@{ Exists = $true; Value = $fakeState.Startup } }
function Set-StartupAction {
    param([string]$StartupAction)
    $fakeState.Startup = $StartupAction
    if ($Scenario -eq 'StartupFailure') { throw 'Injected startup write failure' }
}
function Set-StartupValue { param($Value) $fakeState.Startup = $Value.Value }
function Write-AudioJson {
    param([string]$Path, $Value)
    if ($Scenario -eq 'PendingWriteFailure' -and $Value.Status -eq 'PendingReboot') { throw 'Injected pending settings write failure' }
    $fakeState.Status = $Value.Status
    $fakeState.Boot = $Value.InstallBoot
}
function Start-Process {
    param([string]$FilePath, [string]$ArgumentList, [string]$Verb, [string]$WindowStyle, [switch]$Wait, [switch]$PassThru)
    $fakeState.InstallerCalls++
    $fakeState.ArgumentList = $ArgumentList
    $fakeState.Verb = $Verb
    $fakeState.WindowStyle = $WindowStyle
    $fakeState.Wait = [bool]$Wait
    if ($FilePath -ne 'X:\NeverExecute\fake-installer.exe') { throw 'Unexpected process path' }
    if ($Scenario -eq 'Cancelled') { throw 'Injected UAC cancellation' }
    if ($Scenario -eq 'Nonzero') { return [pscustomobject]@{ ExitCode = 7 } }
    if ($Scenario -in @('SuccessOne', 'OneMissingDriver', 'CleanupFailureOne')) { return [pscustomobject]@{ ExitCode = 1 } }
    return [pscustomobject]@{ ExitCode = 0 }
}
function Get-VoicemeeterDirectory { if ($Scenario -ne 'MissingFiles') { return 'X:\FakeInstalled' } }
function Protect-PendingRebootOutput {
    if ($Scenario -like 'CleanupFailure*' -or $Scenario -eq 'SameBootCleanupFailure') { throw 'Injected deferred endpoint cleanup failure' }
}
function Get-VoicemeeterInstallEvidence {
    param([string]$Directory)
    $complete = $Scenario -notin @('MissingFiles', 'OneMissingDriver', 'ZeroMissingDriver', 'InvalidExisting', 'AdoptInvalid')
    [pscustomobject]@{
        Complete = $complete; Ready = $complete; Issues = @('Injected missing driver evidence'); Directory = $Directory
        ApplicationVersion = '1.1.3.0'; RemoteVersion = '1.1.3.0'; DriverVersion = '3.3.0.4'; DeviceId = 'ROOT\MEDIA\0000'; DriverProblem = 0
    }
}
try {
'@
    $suffix = @'
    $fakeState.Continued = $true
} catch {
    $fakeState.Error = $_.Exception.Message
    exit 1
} finally {
    [IO.File]::WriteAllText($ReportPath, ($fakeState | ConvertTo-Json -Depth 5))
}
'@
    $moduleAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'scripts\windows\Voicemeeter.psm1'), [ref]$null, [ref]$null)
    $resultFunction = $moduleAst.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq 'Get-VoicemeeterInstallResult' }, $true)
    Assert-True ($null -ne $resultFunction) 'Missing installer result function.'
    [IO.File]::WriteAllText($childPath, ($prefix + "`r`n" + $resultFunction.Extent.Text + "`r`n" + $adoptText + "`r`n" + $node.Extent.Text + "`r`n" + $suffix))
    $shell = (Get-Process -Id $PID).Path
    $childOutput = & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath $Scenario $childReport 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True (Test-Path -LiteralPath $childReport) ('Isolated process failed before producing its report: ' + ($childOutput -join ' '))
    return [pscustomobject]@{ ExitCode = $exitCode; State = (Get-Content -LiteralPath $childReport -Raw | ConvertFrom-Json) }
}
foreach ($scenario in @('Cancelled', 'Nonzero', 'MissingFiles', 'OneMissingDriver', 'ZeroMissingDriver', 'StartupFailure', 'PendingWriteFailure')) {
    Test-Case "Installation $scenario restores startup and clears pending reboot state" {
        $result = Invoke-IsolatedInstallState $scenario
        Assert-Equal $result.ExitCode 1
        Assert-Equal $result.State.Status 'InstallFailed'
        Assert-Equal $result.State.Startup 'original startup'
        Assert-True (-not $result.State.Continued)
        if ($scenario -in @('StartupFailure', 'PendingWriteFailure')) { Assert-Equal $result.State.InstallerCalls 0 }
        else { Assert-Equal $result.State.InstallerCalls 1 }
        Assert-True (-not [string]::IsNullOrEmpty($result.State.Error))
    }
}
foreach ($successScenario in @('Success', 'SuccessOne', 'CleanupFailureZero', 'CleanupFailureOne')) {
Test-Case "Successful installation $successScenario schedules resume and returns reboot-required without restarting" {
    $result = Invoke-IsolatedInstallState $successScenario
    Assert-Equal $result.ExitCode 3010
    Assert-Equal $result.State.Status 'PendingReboot'
    Assert-Equal $result.State.Boot 'boot-2'
    Assert-Equal $result.State.Startup 'Resume'
    Assert-Equal $result.State.InstallerCalls 1
    Assert-Equal $result.State.ArgumentList '-h -i'
    Assert-Equal $result.State.Verb 'RunAs'
    Assert-Equal $result.State.WindowStyle 'Hidden'
    Assert-True $result.State.Wait
    Assert-True (-not $result.State.Continued)
}
}
Test-Case 'Resume without installed application fails without retrying installer' {
    $result = Invoke-IsolatedInstallState 'ResumeMissing'
    Assert-Equal $result.ExitCode 1
    Assert-Equal $result.State.InstallerCalls 0
    Assert-Equal $result.State.Startup 'original startup'
    Assert-True ($result.State.Error -match 'not detected')
}
Test-Case 'Pending reboot on the same boot exits before configuration' {
    $result = Invoke-IsolatedInstallState 'SameBoot' -BootGuard
    Assert-Equal $result.ExitCode 3010
    Assert-True (-not $result.State.Continued)
    Assert-Equal $result.State.InstallerCalls 0
    Assert-Equal $result.State.Startup 'original startup'
}
Test-Case 'Pending reboot cleanup failure preserves reboot continuation on the same boot' {
    $result = Invoke-IsolatedInstallState 'SameBootCleanupFailure' -BootGuard
    Assert-Equal $result.ExitCode 3010
    Assert-True (-not $result.State.Continued)
    Assert-Equal $result.State.InstallerCalls 0
    Assert-Equal $result.State.Startup 'original startup'
    Assert-Equal $result.State.Error $null
}
Test-Case 'Pending reboot on a later boot allows configuration to continue' {
    $result = Invoke-IsolatedInstallState 'NewBoot' -BootGuard
    Assert-Equal $result.ExitCode 0
    Assert-True $result.State.Continued
    Assert-Equal $result.State.InstallerCalls 0
}
Test-Case 'Previous installer-code failure adopts verified installation and waits for reboot without reinstalling' {
    $result = Invoke-IsolatedInstallState 'AdoptSameBoot' -Adoption
    Assert-Equal $result.ExitCode 3010
    Assert-Equal $result.State.Status 'PendingReboot'
    Assert-Equal $result.State.Startup 'Resume'
    Assert-Equal $result.State.InstallerCalls 0
    Assert-True (-not $result.State.Continued)
}
Test-Case 'Incomplete failed installation cannot be adopted or retried implicitly' {
    $result = Invoke-IsolatedInstallState 'AdoptInvalid' -Adoption
    Assert-Equal $result.ExitCode 1
    Assert-Equal $result.State.Startup 'original startup'
    Assert-Equal $result.State.InstallerCalls 0
    Assert-True (-not $result.State.Continued)
    Assert-True ($result.State.Error -match 'incomplete')
}
Test-Case 'An existing application with invalid driver evidence cannot enter configuration' {
    $result = Invoke-IsolatedInstallState 'InvalidExisting' -Existing
    Assert-Equal $result.ExitCode 1
    Assert-Equal $result.State.InstallerCalls 0
    Assert-True (-not $result.State.Continued)
    Assert-True ($result.State.Error -match 'driver is not ready')
}

$research = Join-Path $OutputDirectory 'research'
$installer = Join-Path $research 'VoicemeeterSetup_v1130\voicemeetersetup.exe'
$archive = Join-Path $research 'VoicemeeterSetup_v1130.zip'
if (Test-Path -LiteralPath $installer) {
    Test-Case 'Downloaded official installer matches pinned hash and valid publisher signature' {
        Assert-VoicemeeterInstaller $installer
    }
} else { Write-Host 'SKIP official installer verification: cached research installer absent.' }
if (Test-Path -LiteralPath $archive) {
    Test-Case 'Downloaded archive hash and installer entry match extraction contract' {
        Assert-Equal (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() (Get-VoicemeeterPackage).ArchiveSha256
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $entries = @($zip.Entries | Where-Object { $_.FullName -ieq 'voicemeetersetup.exe' })
            Assert-Equal $entries.Count 1
            Assert-True ($entries[0].Length -gt 0)
        } finally { $zip.Dispose() }
    }
} else { Write-Host 'SKIP archive verification: cached research archive absent.' }

$failures = @($results | Where-Object { -not $_.Passed })
$report = [pscustomobject]@{
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    Scope = 'Pure module and isolated transactions with fake Remote/endpoints; no installation, audio changes, registry writes, downloads or receiver access.'
    Passed = $results.Count - $failures.Count
    Failed = $failures.Count
    Results = @($results.ToArray())
}
$reportPath = Join-Path $OutputDirectory ('tests-powershell-' + $PSVersionTable.PSVersion.Major + '.json')
Write-AudioJson $reportPath $report
Write-Host "$($report.Passed) passed, $($report.Failed) failed. Report: $reportPath"
if ($failures.Count -gt 0) { exit 1 }
exit 0
