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
    public int MixerType = 1;
    public string IgnoreWrite = null;
    public string FailWrite = null;
    public string FailRead = null;
    public string SaveContent = "<Voicemeeter><VBAN /></Voicemeeter>";
    public bool SkipSave = false;
    public int Type() { return MixerType; }
    public int Dirty() { if (FailRead == "Dirty") throw new InvalidOperationException("Read API failed"); return 0; }
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
    }
}
public sealed class DesktopAudioTestEndpoint {
    public string Id;
    public bool Active = true;
}
public static class DesktopAudioTestEndpoints {
    public static readonly string[] Defaults = new string[] { "speaker0", "speaker1", "speaker2" };
    public static string GetDefault(int role) { return Defaults[role]; }
    public static void SetDefault(string id, int role) { Defaults[role] = id; }
    public static object[] ListRender() {
        return new object[] {
            new DesktopAudioTestEndpoint { Id = "speaker0" },
            new DesktopAudioTestEndpoint { Id = "speaker1" },
            new DesktopAudioTestEndpoint { Id = "speaker2" },
            new DesktopAudioTestEndpoint { Id = "virtual" }
        };
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
    if (-not $node) { throw "Missing production function: $Name" }
    return [scriptblock]::Create($node.Extent.Text.Replace('[LanAudioBridge.WindowsAudio.Endpoints]', '[DesktopAudioTestEndpoints]'))
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
foreach ($failureMode in @('Startup', 'Settings', 'MixerRollback', 'EndpointRollback', 'StartupRollback', 'ProfileRollback', 'FreshProfile')) {
    Test-Case "Configuration transaction independently recovers from $failureMode failure" {
        . (Get-IsolatedFunction 'Get-DefaultEndpoints')
        . (Get-IsolatedFunction 'Restore-DefaultEndpoints')
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
        $remote = New-Object DesktopAudioTestRemote
        if ($failureMode -eq 'MixerRollback') { $remote.FailWrite = 'Command.Load' }
        if ($failureMode -eq 'EndpointRollback') {
            function Restore-DefaultEndpoints { param($Defaults) throw 'Injected device unavailable' }
        }
        $slot = 0
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
        function Write-AudioJson { param([string]$Path, $Value) throw 'Injected settings failure' }
        try { Assert-Throws { . $isolated } 'Injected (startup|settings) failure' }
        finally { if ($fakeState.ProfileLock) { $fakeState.ProfileLock.Dispose() } }
        if ($failureMode -eq 'FreshProfile') { Assert-True (-not (Test-Path -LiteralPath $desktopProfile)) }
        elseif ($failureMode -eq 'ProfileRollback') { Assert-Equal ([IO.File]::ReadAllText($desktopProfile)) $remote.SaveContent }
        else { Assert-Equal ([IO.File]::ReadAllText($desktopProfile)) '<original-desktop />' }
        if ($failureMode -eq 'StartupRollback') { Assert-Equal $fakeState.Startup.Value 'Start' }
        else { Assert-Equal $fakeState.Startup.Value 'prior command' }
        if ($failureMode -ne 'EndpointRollback') {
            foreach ($role in 0..2) { Assert-Equal ([DesktopAudioTestEndpoints]::GetDefault($role)) "speaker$role" }
        }
        if ($failureMode -ne 'MixerRollback') {
            Assert-True $remote.Writes.Contains('Command.Load=' + $transaction) 'Mixer rollback was not requested.'
        }
        Assert-True (-not (Test-Path -LiteralPath $settingsPath)) 'Failed settings must not be committed.'
    }
}

# Keep exit statements intact: run only the selected production AST in a child
# PowerShell, with every side-effecting command replaced by an in-memory fake.
function Invoke-IsolatedInstallState {
    param([string]$Scenario, [switch]$BootGuard)
    if ($BootGuard) {
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
        'Write-AudioJson', 'Set-StartupAction', 'Start-Process', 'Get-VoicemeeterDirectory', 'Set-StartupValue')
    foreach ($command in $node.FindAll({ param($ast) $ast -is [Management.Automation.Language.CommandAst] }, $true)) {
        Assert-True ($allowedCommands -contains $command.GetCommandName()) "Unexpected installer command requires an explicit fake: $($command.GetCommandName())"
    }
    Assert-Equal @($node.FindAll({ param($ast) $ast -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)).Count 0 'Unexpected direct API call in isolated installer'
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
if ($Scenario -eq 'SameBoot') { $settings.InstallBoot = $boot }
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
    return [pscustomobject]@{ ExitCode = 0 }
}
function Get-VoicemeeterDirectory { if ($Scenario -ne 'MissingFiles') { return 'X:\FakeInstalled' } }
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
    [IO.File]::WriteAllText($childPath, ($prefix + "`r`n" + $node.Extent.Text + "`r`n" + $suffix))
    $shell = (Get-Process -Id $PID).Path
    $childOutput = & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath $Scenario $childReport 2>&1
    $exitCode = $LASTEXITCODE
    Assert-True (Test-Path -LiteralPath $childReport) ('Isolated process failed before producing its report: ' + ($childOutput -join ' '))
    return [pscustomobject]@{ ExitCode = $exitCode; State = (Get-Content -LiteralPath $childReport -Raw | ConvertFrom-Json) }
}
foreach ($scenario in @('Cancelled', 'Nonzero', 'MissingFiles', 'StartupFailure', 'PendingWriteFailure')) {
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
Test-Case 'Successful installation schedules resume and returns reboot-required without restarting' {
    $result = Invoke-IsolatedInstallState 'Success'
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
Test-Case 'Pending reboot on a later boot allows configuration to continue' {
    $result = Invoke-IsolatedInstallState 'NewBoot' -BootGuard
    Assert-Equal $result.ExitCode 0
    Assert-True $result.State.Continued
    Assert-Equal $result.State.InstallerCalls 0
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
