# Copyright (c) 2026 LAN Audio Bridge contributors.
# SPDX-License-Identifier: MIT
# Default tests use an in-memory registry/native backend and write only temporary backups.
[CmdletBinding()]
param([switch]$ReadCurrentDriver,[string]$ControlPanelPath='C:\Program Files (x86)\VB\Voicemeeter\VBVoicemeeterVAIO_ControlPanel.exe')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\DriverOptions.psm1') -Force -PassThru
if($ReadCurrentDriver){$liveBefore=Get-DriverVolumeControlState $ControlPanelPath}
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('lan-audio-driver-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testDirectory
$launcherDirectory=Join-Path $testDirectory 'launcher'
$null=New-Item -ItemType Directory -Path $launcherDirectory
try {
 & $module {
  param($directory)
  $script:checks=0
  function Assert-True($condition,[string]$label){if(-not $condition){throw $label};$script:checks++}
  function Assert-Fails([scriptblock]$action,[string]$message){try{& $action}catch{if($_.Exception.ToString() -notmatch [regex]::Escape($message)){throw};$script:checks++;return};throw ('Expected failure: '+$message)}
  function Copy-State($value){$value | ConvertTo-Json -Depth 7 | ConvertFrom-Json}
  $baseline=[pscustomobject]@{Schema=1;ControlPanelHash=$script:PanelHash;ValueName=$script:ValueName;RuntimeEnabled=$false;Registry=@(foreach($target in Get-DriverOptionsTargets){[pscustomobject]@{View=$target.View;Path=$target.Path;Exists=$false;Kind=$null;Value=$null}})}
  Assert-DriverOptionsSnapshot $baseline
  $bad=Copy-State $baseline;$bad.Registry[0].Path='SOFTWARE\Other'
  Assert-Fails {Assert-DriverOptionsSnapshot $bad} 'Invalid VAIO option target'
  $bad=Copy-State $baseline;$bad.Registry[0].Exists=$true;$bad.Registry[0].Kind='String';$bad.Registry[0].Value='1'
  Assert-Fails {Assert-DriverOptionsSnapshot $bad} 'Unsupported existing VAIO volume option'
  $bad=Copy-State $baseline;$bad.ValueName='VBVoicemeeterVAIO_LoopBack'
  Assert-Fails {Assert-DriverOptionsSnapshot $bad} 'Invalid VAIO option snapshot'
  Assert-Fails {Assert-DriverOptionsPanel 'relative.exe'} 'absolute path'
  $script:fake=Copy-State $baseline;$script:writes=0;$script:failOnce=$false;$script:failNative=$false
  function script:Assert-DriverOptionsAdministrator {}
  function script:Assert-DriverOptionsPanel {param($ControlPanelPath)}
  function script:Initialize-DriverOptionsNative {}
  function script:Get-DriverVolumeControlState {param($ControlPanelPath);Copy-State $script:fake}
  function script:Write-DriverOptionsRegistryValue {
   param($Target,[bool]$Exists,[int]$Value)
   $script:writes++
   if($script:failOnce -and $script:writes -eq 2){$script:failOnce=$false;throw 'injected second registry write failure'}
   $r=@($script:fake.Registry | Where-Object {$_.Path -ceq $Target.Path -and $_.View -ceq $Target.View})
   if($r.Count -ne 1){throw 'Unexpected registry target'}
   $r[0].Exists=$Exists;$r[0].Kind=if($Exists){'DWord'}else{$null};$r[0].Value=if($Exists){$Value}else{$null}
  }
  function script:Set-DriverOptionsRuntime {param([bool]$Enabled);if($script:failNative -and $Enabled){$script:failNative=$false;throw 'injected native apply failure'};$script:fake.RuntimeEnabled=$Enabled;return $Enabled}
  $path=Join-Path $directory 'success.json'
  $change=Enable-DriverWindowsVolumeControl 'verified.exe' $path
  Assert-True $change.After.RuntimeEnabled 'Native option enabled'
  Assert-True (@($change.After.Registry | Where-Object {$_.Value -ne 1 -or $_.Kind -ne 'DWord'}).Count -eq 0) 'Three persistent DWORD values'
  Assert-True ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).RuntimeEnabled -eq $false) 'Original runtime state saved before mutation'
  $writeCount=$script:writes
  Assert-Fails {Enable-DriverWindowsVolumeControl 'verified.exe' $path} 'already exists'
  Assert-True ($script:writes -eq $writeCount) 'Existing backup prevents mutation'
  $restored=Restore-DriverVolumeControlState 'verified.exe' $baseline
  Assert-True (-not $restored.RuntimeEnabled -and @($restored.Registry | Where-Object {$_.Exists}).Count -eq 0) 'Rollback deletes originally absent values'
  $script:fake=Copy-State $baseline;$script:writes=0;$script:failOnce=$true
  Assert-Fails {Enable-DriverWindowsVolumeControl 'verified.exe' (Join-Path $directory 'registry-failure.json')} 'Original VAIO option state was restored'
  Assert-True (($script:fake | ConvertTo-Json -Depth 6 -Compress) -ceq ($baseline | ConvertTo-Json -Depth 6 -Compress)) 'Partial registry failure rolls back all targets'
  $script:fake=Copy-State $baseline;$script:failNative=$true
  Assert-Fails {Enable-DriverWindowsVolumeControl 'verified.exe' (Join-Path $directory 'native-failure.json')} 'Original VAIO option state was restored'
  Assert-True (($script:fake | ConvertTo-Json -Depth 6 -Compress) -ceq ($baseline | ConvertTo-Json -Depth 6 -Compress)) 'Native failure rolls back persistent values'
  Write-Output ('Passed '+$script:checks+' driver option checks; machine state was not changed.')
 } $testDirectory
 & {
  param($directory, $scriptsDirectory)
  $checks = 0
  function Assert-Launcher($condition, [string]$label) {
   if (-not $condition) { throw $label }
   $script:launcherChecks++
  }
  function Assert-LauncherFails([scriptblock]$action, [string]$message) {
   try { & $action } catch {
    if ($_.Exception.Message -notmatch [regex]::Escape($message)) { throw }
    $script:launcherChecks++
    return
   }
   throw ('Expected failure: ' + $message)
  }
  $script:launcherChecks = 0
  $tokens = $null; $parseErrors = $null
  $launcher = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory 'windows-audio.ps1'), [ref]$tokens, [ref]$parseErrors)
  Assert-Launcher ($parseErrors.Count -eq 0) 'Launcher syntax'
  $helperNames = @('Test-DriverVolumeEnabled', 'Invoke-DriverVolumeAction', 'Ensure-DriverVolumeControl', 'Restore-DriverVolumeControl', 'Copy-LocalProgram')
  foreach ($name in $helperNames) {
   $node = $launcher.Find({ param($ast) $ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq $name }, $true)
   if (-not $node) { throw ('Missing launcher function ' + $name) }
   . ([scriptblock]::Create($node.Extent.Text.Replace('$PSScriptRoot', '$scriptsDirectory')))
  }
  $stateRoot = $directory
  $programRoot = Join-Path $directory 'program'
  $originalPath = Join-Path $directory 'driver-volume-original.json'
  $script:fixture = [pscustomobject]@{
   Schema = 1; ControlPanelHash = 'fixture'; ValueName = 'VBVoicemeeterVAIO_VolCtl'; RuntimeEnabled = $true
   Registry = @([pscustomobject]@{ Exists = $true; Kind = 'DWord'; Value = 1 })
  }
  $script:launchCount = 0
  $script:launchMode = 'Success'
  function Get-DriverVolumeControlState { param($ControlPanelPath); $script:fixture | ConvertTo-Json -Depth 6 | ConvertFrom-Json }
  function Start-Process {
   param($FilePath, $ArgumentList, $Verb, $WindowStyle, [switch]$Wait, [switch]$PassThru)
   $script:launchCount++
   Assert-Launcher ($FilePath -like '*\System32\WindowsPowerShell\v1.0\powershell.exe') 'Fixed elevated interpreter'
   Assert-Launcher ($Verb -eq 'RunAs' -and $WindowStyle -eq 'Hidden' -and $Wait -and $PassThru) 'Narrow hidden UAC execution'
   Assert-Launcher ($ArgumentList -match '^\-NoProfile \-ExecutionPolicy Bypass \-File ".*windows-driver-volume.ps1" \-Action (Enable|Restore)$') 'Only fixed action arguments'
   if ($script:launchMode -eq 'Cancel') { throw 'UAC cancelled fixture' }
   $action = $Matches[1]
   if ($script:launchMode -eq 'Success') {
    if ($action -eq 'Enable') {
     $script:fixture.RuntimeEnabled = $true
     $script:fixture.Registry[0].Exists = $true
     $script:fixture.Registry[0].Kind = 'DWord'
     $script:fixture.Registry[0].Value = 1
    } else {
     $script:fixture = Get-Content -LiteralPath $originalPath -Raw | ConvertFrom-Json
    }
   }
   [pscustomobject]@{ Schema = 1; Action = $action; Succeeded = ($script:launchMode -ne 'Failure'); Error = 'fixture child failure' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'driver-volume-result.json')
   return [pscustomobject]@{ ExitCode = $(if ($script:launchMode -eq 'Failure') { 1 } else { 0 }) }
  }
  Ensure-DriverVolumeControl 'C:\fixture'
  Assert-Launcher ($script:launchCount -eq 0) 'Already enabled setup needs no UAC'
  Assert-Launcher (Test-Path -LiteralPath $originalPath) 'First original state preserved'
  $first = Get-Content -LiteralPath $originalPath -Raw | ConvertFrom-Json
  $first.RuntimeEnabled = $false
  $first.Registry[0].Exists = $false; $first.Registry[0].Kind = $null; $first.Registry[0].Value = $null
  $first | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $originalPath
  $firstBytes = [IO.File]::ReadAllText($originalPath)
  Ensure-DriverVolumeControl 'C:\fixture'
  Assert-Launcher ([IO.File]::ReadAllText($originalPath) -ceq $firstBytes) 'Repeated setup preserves first backup bytes'
  Ensure-DriverVolumeControl 'C:\fixture' -ReadOnly
  Assert-Launcher ($script:launchCount -eq 0) 'Enabled startup is read only'
  $script:fixture.RuntimeEnabled = $false
  Assert-LauncherFails { Ensure-DriverVolumeControl 'C:\fixture' -ReadOnly } 'startup does not request'
  Assert-Launcher ($script:launchCount -eq 0) 'Disabled startup never elevates'
  Ensure-DriverVolumeControl 'C:\fixture'
  Assert-Launcher ($script:fixture.RuntimeEnabled -and $script:launchCount -eq 1) 'Setup enables and independently reads back'
  $script:fixture.RuntimeEnabled = $false; $script:launchMode = 'Cancel'
  Assert-LauncherFails { Ensure-DriverVolumeControl 'C:\fixture' } 'UAC cancelled'
  Assert-Launcher (-not $script:fixture.RuntimeEnabled) 'Cancelled UAC preserves state'
  $script:launchMode = 'Failure'
  Assert-LauncherFails { Ensure-DriverVolumeControl 'C:\fixture' } 'fixture child failure'
  $script:launchMode = 'NoChange'
  Assert-LauncherFails { Ensure-DriverVolumeControl 'C:\fixture' } 'independent readback'
  $script:launchMode = 'Success'; $script:fixture.RuntimeEnabled = $true
  Restore-DriverVolumeControl 'C:\fixture'
  Assert-Launcher (-not $script:fixture.RuntimeEnabled -and -not $script:fixture.Registry[0].Exists) 'Restore uses first snapshot'
  $countBefore = $script:launchCount
  Restore-DriverVolumeControl 'C:\fixture'
  Assert-Launcher ($script:launchCount -eq $countBefore) 'Already restored option needs no UAC'
  Copy-LocalProgram
  Assert-Launcher (Test-Path -LiteralPath (Join-Path $programRoot 'windows\DriverOptions.psm1')) 'Module copied for startup'
  Assert-Launcher (Test-Path -LiteralPath (Join-Path $programRoot 'windows-driver-volume.ps1')) 'Narrow helper copied for setup'
  $childTokens = $null; $childErrors = $null
  $child = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scriptsDirectory 'windows-driver-volume.ps1'), [ref]$childTokens, [ref]$childErrors)
  Assert-Launcher ($childErrors.Count -eq 0 -and $child.ParamBlock.Parameters.Count -eq 1) 'Child accepts only action'
  Assert-Launcher ($child.ParamBlock.Parameters[0].Name.VariablePath.UserPath -eq 'Action') 'No elevated caller path parameter'
  $startBranch = $launcher.Find({ param($ast) $ast -is [Management.Automation.Language.IfStatementAst] -and $ast.Clauses[0].Item1.Extent.Text -eq '$Action -eq ''Start''' }, $true)
  Assert-Launcher ($startBranch.Extent.Text -match 'Ensure-DriverVolumeControl -Directory \$directory -ReadOnly') 'Start wired to read-only check'
  Write-Output ('Passed ' + $script:launcherChecks + ' launcher checks with fake UAC and no machine changes.')
 } $launcherDirectory (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts')
} finally {
 Remove-Module $module
 # Only exact files generated in this fresh test directory are removed; no recursive deletion.
 foreach($name in @('success.json','registry-failure.json','native-failure.json')){Remove-Item -LiteralPath (Join-Path $testDirectory $name) -Force -ErrorAction SilentlyContinue}
 if (Test-Path -LiteralPath $launcherDirectory) {
  $cleanupRoot = [IO.Path]::GetFullPath($launcherDirectory).TrimEnd('\') + '\'
  $children = @(Get-ChildItem -LiteralPath $launcherDirectory -Recurse -Force)
  foreach ($child in $children) {
   if (-not $child.FullName.StartsWith($cleanupRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test cleanup path is outside its fresh temporary directory.'
   }
  }
  foreach ($child in @($children | Where-Object { -not $_.PSIsContainer })) {
   Remove-Item -LiteralPath $child.FullName -Force
  }
  foreach ($child in @($children | Where-Object PSIsContainer | Sort-Object { $_.FullName.Length } -Descending)) {
   Remove-Item -LiteralPath $child.FullName -Force
  }
  Remove-Item -LiteralPath $launcherDirectory -Force
 }
 Remove-Item -LiteralPath $testDirectory -Force -ErrorAction SilentlyContinue
}
if($ReadCurrentDriver){
 Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\DriverOptions.psm1') -Force
 $liveAfter=Get-DriverVolumeControlState $ControlPanelPath
 if(($liveBefore | ConvertTo-Json -Depth 6 -Compress) -cne ($liveAfter | ConvertTo-Json -Depth 6 -Compress)){throw 'Read-only live state changed during the tests.'}
 Write-Output ('Native read-only ABI check passed. Runtime enabled: '+$liveAfter.RuntimeEnabled)
}
