# Copyright (c) 2026 LAN Audio Bridge contributors. MIT license.
# In-memory registry/system backend only; does not change the running installation.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\EngineOptions.psm1') -Force -PassThru
$directory = Join-Path ([IO.Path]::GetTempPath()) ('lan-audio-engine-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
try {
    & $module {
        param($directory)
        $script:checks = 0
        function Assert-True($value, $message) {
            if (-not $value) { throw $message }
            $script:checks++
        }
        function Assert-Fails([scriptblock]$action, $message) {
            try { & $action } catch {
                if ($_.Exception.ToString() -notmatch [regex]::Escape($message)) { throw }
                $script:checks++
                return
            }
            throw ('Expected failure: ' + $message)
        }
        function Copy-State($value) {
            [Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($value, 5))
        }
        $exe = 'C:\verified\voicemeeter.exe'
        $script:running = $false
        $script:wrongImage = $false
        $script:writes = 0
        $script:failWrite = ''
        $script:fake = [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = [int]7168 }
        function script:Assert-EngineImage {
            param($VoicemeeterPath)
            if ($script:wrongImage) { throw 'Unsupported image' }
        }
        function script:Assert-EngineStopped {
            if ($script:running) { throw 'Engine must be stopped' }
        }
        function script:Get-EngineUserSid { 'test-user' }
        function script:Read-EngineValue { Copy-State $script:fake }
        function script:Write-EngineValue {
            param($Snapshot)
            $script:writes++
            if ($script:failWrite -eq 'before') { $script:failWrite = ''; throw 'Injected write failure' }
            $script:fake = [pscustomobject]@{ Exists = $Snapshot.Exists; Kind = $Snapshot.Kind; Value = $Snapshot.Value }
            if ($script:failWrite -eq 'after') { $script:failWrite = ''; throw 'Injected write failure after mutation' }
        }
        $original = Get-VoicemeeterEngineState $exe
        $backup = Join-Path $directory 'original.clixml'
        $script:running = $true
        Assert-Fails { Set-VoicemeeterEngineLatency $exe $backup } 'must be stopped'
        Assert-True ($script:writes -eq 0 -and -not (Test-Path -LiteralPath $backup)) 'Running engine is untouched'
        $script:running = $false
        $script:wrongImage = $true
        Assert-Fails { Set-VoicemeeterEngineLatency $exe $backup } 'Unsupported image'
        Assert-True ($script:writes -eq 0) 'Wrong image is untouched'
        $script:wrongImage = $false
        $result = Set-VoicemeeterEngineLatency $exe $backup
        Assert-True ($result.Changed -and $result.After.Optimized -and $result.After.Value -eq 3072) 'Expected latency applied'
        $saved = Import-Clixml -LiteralPath $backup
        Assert-True ($saved.Value -eq 7168 -and $saved.Kind -ceq 'DWord' -and $saved.Exists) 'Exact original snapshot persisted'
        $bytes = [IO.File]::ReadAllText($backup)
        $count = $script:writes
        $result = Set-VoicemeeterEngineLatency $exe $backup
        Assert-True (-not $result.Changed -and $script:writes -eq $count) 'Idempotent Set performs no registry write'
        Assert-True ([IO.File]::ReadAllText($backup) -ceq $bytes) 'Idempotent Set preserves first backup'
        $script:fake.Value = [int]2048
        Assert-Fails { Restore-VoicemeeterEngineState $exe $saved } 'conflicting value'
        Assert-Fails { Set-VoicemeeterEngineLatency $exe $backup } 'conflicting value'
        Assert-True ($script:fake.Value -eq 2048 -and $script:writes -eq $count) 'External change is not overwritten'
        $script:fake.Value = [int]3072
        $restored = Restore-VoicemeeterEngineState $exe $saved
        Assert-True ($restored.Value -eq 7168) 'Original DWORD restored'
        $count = $script:writes
        $null = Restore-VoicemeeterEngineState $exe $saved
        Assert-True ($script:writes -eq $count) 'Idempotent restore performs no write'
        foreach ($timing in @('before', 'after')) {
            $script:failWrite = $timing
            Assert-Fails { Set-VoicemeeterEngineLatency $exe (Join-Path $directory ($timing + '.clixml')) } 'Original native engine value was restored'
            Assert-True ($script:fake.Value -eq 7168) ('Write failure restored old value: ' + $timing)
        }
        $script:fake = [pscustomobject]@{ Exists = $false; Kind = $null; Value = $null }
        $absentPath = Join-Path $directory 'absent.clixml'
        $null = Set-VoicemeeterEngineLatency $exe $absentPath
        $restored = Restore-VoicemeeterEngineState $exe (Import-Clixml -LiteralPath $absentPath)
        Assert-True (-not $restored.Exists -and $null -eq $restored.Kind -and $null -eq $restored.Value) 'Originally absent value removed on restore'
        $script:fake = [pscustomobject]@{ Exists = $true; Kind = 'String'; Value = '7168' }
        Assert-Fails { Set-VoicemeeterEngineLatency $exe $backup } 'Unsupported existing VAIO latency layout'
        $script:fake = [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = [int]128 }
        Assert-Fails { Set-VoicemeeterEngineLatency $exe $backup } 'Unsupported existing VAIO latency layout'
        $script:fake = [pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = [int]7168 }
        foreach ($field in @('Name', 'UserSid', 'ImageHash', 'Key')) {
            $bad = Copy-State $original
            $bad.$field = 'other'
            Assert-Fails { Restore-VoicemeeterEngineState $exe $bad } 'Invalid native engine snapshot'
        }
        # The production writer has exactly one constant value name, with no clock or bulk-key writes.
        Assert-True ($script:EngineValue -ceq 'VAIOLatency6') 'Only the ordinary VAIO pair is targeted'
        Write-Output ('Passed ' + $script:checks + ' native engine checks; real registry and processes were not changed.')
    } $directory
} finally {
    Remove-Module $module
    foreach ($name in @('original.clixml', 'before.clixml', 'after.clixml', 'absent.clixml')) {
        Remove-Item -LiteralPath (Join-Path $directory $name) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
}
