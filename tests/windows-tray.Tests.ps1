# Runs only against a fake registry/system backend. Never stops or starts processes.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$module=Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\windows\TrayOptions.psm1') -Force -PassThru
$directory=Join-Path ([IO.Path]::GetTempPath()) ('lan-audio-tray-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
try {
 & $module {
    param($directory)
    $script:checks=0
    function Assert-True($value,$message){if(-not $value){throw $message};$script:checks++}
    function Assert-Fails([scriptblock]$action,$message){try{& $action}catch{if($_.Exception.ToString() -notmatch [regex]::Escape($message)){throw};$script:checks++;return};throw ('Expected failure: '+$message)}
    function Copy-State($value){[Management.Automation.PSSerializer]::Deserialize([Management.Automation.PSSerializer]::Serialize($value,8))}
    # Exercise production version/hash/signature checks with fake file metadata.
    function script:Get-Item {param($LiteralPath,$ErrorAction);[pscustomobject]@{VersionInfo=[pscustomobject]@{FileMajorPart=1;FileMinorPart=1;FileBuildPart=$script:build;FilePrivatePart=0}}}
    function script:Get-FileHash {param($LiteralPath,$Algorithm,$ErrorAction);[pscustomobject]@{Hash=$script:hash}}
    function script:Get-AuthenticodeSignature {param($LiteralPath,$ErrorAction);[pscustomobject]@{Status=$script:signature;SignerCertificate=[pscustomobject]@{Thumbprint=$script:signer}}}
    function script:Get-TrayUserSid {'S-1-5-21-test'}
    function script:Get-Process {param($ErrorAction);if($script:running){[pscustomobject]@{ProcessName='voicemeeter8'}}}
    $script:build=3;$script:hash=$script:TrayHash;$script:signature='Valid';$script:signer=$script:TraySigner;$script:running=$false
    $exe='C:\verified\voicemeeter.exe'
    Assert-TrayImage $exe
    Assert-Fails {Assert-TrayImage 'relative.exe'} 'absolute path'
    $script:build=4;Assert-Fails {Assert-TrayImage $exe} 'Unsupported';$script:build=3
    $script:hash='different';Assert-Fails {Assert-TrayImage $exe} 'Unsupported';$script:hash=$script:TrayHash
    $script:signature='NotSigned';Assert-Fails {Assert-TrayImage $exe} 'signature';$script:signature='Valid'
    $script:signer='different';Assert-Fails {Assert-TrayImage $exe} 'signature';$script:signer=$script:TraySigner
    $baseline=@([pscustomobject]@{Name='SysTray';Exists=$true;Kind='ExpandString';Value='%USERPROFILE%\unchanged'},[pscustomobject]@{Name='SysTrayShowOnRun';Exists=$false;Kind=$null;Value=$null})
    $script:fake=Copy-State $baseline;$script:unrelated='unchanged';$script:writes=0;$script:failOnce=$false;$script:badReadback=$false
    function script:Read-TrayValues {Copy-State $script:fake}
    function script:Write-TrayValue {
        param($Row)
        $script:writes++
        if($script:failOnce -and $script:writes -eq 2){$script:failOnce=$false;throw 'injected second write failure'}
        $index=[array]::IndexOf($script:TrayNames,$Row.Name)
        if($index -lt 0){throw 'Unexpected target'}
        $script:fake[$index]=Copy-State $Row
        if($script:badReadback -and $script:writes -eq 2){$script:fake[$index].Value=1;$script:badReadback=$false}
    }
    $snapshot=Get-VoicemeeterTrayState $exe
    $bad=Copy-State $snapshot;$bad.Values[0].Name='Other'
    Assert-Fails {Assert-TraySnapshot $bad} 'target'
    $bad=Copy-State $snapshot;$bad.UserSid='other'
    Assert-Fails {Assert-TraySnapshot $bad} 'snapshot'
    $backup=Join-Path $directory 'original.clixml'
    $script:running=$true
    Assert-Fails {Set-VoicemeeterTrayMode $exe $backup} 'must be stopped'
    Assert-True ($script:writes -eq 0 -and -not (Test-Path -LiteralPath $backup)) 'Running process refusal has no writes or backup'
    $script:running=$false
    $result=Set-VoicemeeterTrayMode $exe $backup
    Assert-True ($result.Changed -and $result.After.Enabled -and $result.RestartRequired) 'Native tray configuration enabled'
    $original=Import-Clixml -LiteralPath $backup
    Assert-True ($original.Values[0].Kind -ceq 'ExpandString' -and $original.Values[0].Value -ceq '%USERPROFILE%\unchanged' -and -not $original.Values[1].Exists) 'Exact old type and existence backed up'
    $originalBytes=[IO.File]::ReadAllText($backup)
    $script:running=$true;$count=$script:writes
    $result=Set-VoicemeeterTrayMode $exe $backup
    Assert-True (-not $result.Changed -and -not $result.RestartRequired -and $script:writes -eq $count) 'Already configured login needs no restart or writes'
    Assert-Fails {Restore-VoicemeeterTrayState $exe $original} 'must be stopped'
    $script:running=$false
    $restored=Restore-VoicemeeterTrayState $exe $original
    Assert-True (($restored.Values | ConvertTo-Json -Depth 5 -Compress) -ceq ($baseline | ConvertTo-Json -Depth 5 -Compress)) 'Exact restore of original values'
    $null=Set-VoicemeeterTrayMode $exe $backup
    Assert-True ([IO.File]::ReadAllText($backup) -ceq $originalBytes) 'Retry preserves original backup'
    foreach($scenario in @('failure','readback')) {
        $script:fake=Copy-State $baseline;$script:writes=0;$script:failOnce=($scenario -eq 'failure');$script:badReadback=($scenario -eq 'readback')
        Assert-Fails {Set-VoicemeeterTrayMode $exe (Join-Path $directory ($scenario+'.clixml'))} 'Original native tray values were restored'
        Assert-True (($script:fake | ConvertTo-Json -Depth 5 -Compress) -ceq ($baseline | ConvertTo-Json -Depth 5 -Compress)) 'Failure rolls back partial writes'
    }
    Assert-True ($script:unrelated -ceq 'unchanged') 'Non-target configuration is preserved'
    foreach($case in @(@('DWord',[int]-1),@('QWord',[long]::MaxValue),@('Binary',[byte[]]@(0,255)),@('None',[byte[]]@()),@('MultiString',[string[]]@('a','b')), @('String',''))) {
        $typed=Copy-State $snapshot;$typed.Values[0].Kind=$case[0];$typed.Values[0].Value=$case[1]
        $typed=Copy-State $typed
        Assert-TraySnapshot $typed
        $after=Restore-VoicemeeterTrayState $exe $typed
        Assert-True (($after.Values | ConvertTo-Json -Depth 5 -Compress) -ceq ($typed.Values | ConvertTo-Json -Depth 5 -Compress)) ('Exact type roundtrip '+$case[0])
    }
    $badBackup=Join-Path $directory 'bad.clixml';Set-Content -LiteralPath $badBackup -Value 'invalid'
    $count=$script:writes
    Assert-Fails {Set-VoicemeeterTrayMode $exe $badBackup} 'Data at the root level'
    Assert-True ($script:writes -eq $count) 'Corrupt backup refuses mutation'
    Write-Output ('Passed '+$script:checks+' native tray checks; no real registry or processes were changed.')
 } $directory
} finally {
    Remove-Module $module
    foreach($name in @('original.clixml','failure.clixml','readback.clixml','bad.clixml')) {Remove-Item -LiteralPath (Join-Path $directory $name) -Force -ErrorAction SilentlyContinue}
    Remove-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
}
