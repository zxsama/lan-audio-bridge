# Copyright (c) 2026 LAN Audio Bridge contributors.
# SPDX-License-Identifier: MIT
Set-StrictMode -Version 2.0

# VAIO Control Panel 3.3.1.9, SHA256 below, implements this native option.
# Menu handler 0x40909c -> registry helper 0x404540 -> IOCTL helper 0x403620.
# Readback helper 0x404860 returns 416 bytes; byte 0x174 bit 1 is VolCtl.
$script:PanelHash = '082424386CB4AFA8BF35FD54BD10DDFF6A264B0D0540EEF3BF7711E8EE93D61C'
$script:ValueName = 'VBVoicemeeterVAIO_VolCtl'

function Assert-DriverOptionsPanel {
    param([Parameter(Mandatory)][string]$ControlPanelPath)
    if (-not [IO.Path]::IsPathRooted($ControlPanelPath) -or
        [IO.Path]::GetFileName($ControlPanelPath) -cne 'VBVoicemeeterVAIO_ControlPanel.exe') {
        throw 'An absolute path to VBVoicemeeterVAIO_ControlPanel.exe is required.'
    }
    if ((Get-FileHash -LiteralPath $ControlPanelPath -Algorithm SHA256).Hash -cne $script:PanelHash) {
        throw 'Unsupported VAIO control panel build; native driver options were not changed.'
    }
    $image = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\VBVoicemeeterVAIOMME' -Name ImagePath).ImagePath
    if ($image -notmatch '^\\SystemRoot\\System32\\DriverStore\\FileRepository\\vbvoicemeetervaio64_win10\.inf_amd64_[a-f0-9]+\\vbvoicemeetervaio64_win10\.sys$') {
        throw 'Unexpected VAIO driver service image path.'
    }
    $driverPath = Join-Path $env:SystemRoot $image.Substring(12)
    if ((Get-FileHash -LiteralPath $driverPath -Algorithm SHA256).Hash -cne 'B1F90A0359C267AE1FB220A56BA0E58455DB09A017A37FA101282FCBCC550EBC') {
        throw 'Unsupported VAIO driver build; expected the verified 3.4.1.9 driver.'
    }
}

function Initialize-DriverOptionsNative {
    if ('LanAudioBridge.DriverOptions.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace LanAudioBridge.DriverOptions {
 public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct InterfaceData { public uint Size; public Guid ClassGuid; public uint Flags; public UIntPtr Reserved; }
  [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid guid,IntPtr enumerator,IntPtr hwnd,uint flags);
  [DllImport("setupapi.dll",SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr set,IntPtr device,ref Guid guid,uint index,ref InterfaceData data);
  [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set,ref InterfaceData data,IntPtr detail,uint size,out uint needed,IntPtr device);
  [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle file,uint code,byte[] input,uint inputSize,byte[] output,uint outputSize,out uint bytes,IntPtr overlapped);
  static readonly Guid InterfaceGuid=new Guid("3f594749-d668-404a-84ea-5026b8437752");
  static SafeFileHandle Open() {
   Guid guid=InterfaceGuid; IntPtr set=SetupDiGetClassDevs(ref guid,IntPtr.Zero,IntPtr.Zero,0x12);
   if(set==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());
   var paths=new List<string>();
   try { for(uint index=0;;index++) {
    var data=new InterfaceData {Size=(uint)Marshal.SizeOf(typeof(InterfaceData))};
    if(!SetupDiEnumDeviceInterfaces(set,IntPtr.Zero,ref guid,index,ref data)){int err=Marshal.GetLastWin32Error();if(err==259)break;throw new Win32Exception(err);}
    uint size;SetupDiGetDeviceInterfaceDetail(set,ref data,IntPtr.Zero,0,out size,IntPtr.Zero);
    if(size<8||size>65536)throw new InvalidOperationException("Invalid VAIO interface detail size.");
    IntPtr detail=Marshal.AllocHGlobal((int)size);
    try {Marshal.WriteInt32(detail,IntPtr.Size==8?8:6);if(!SetupDiGetDeviceInterfaceDetail(set,ref data,detail,size,out size,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());paths.Add(Marshal.PtrToStringUni(IntPtr.Add(detail,4)));}
    finally {Marshal.FreeHGlobal(detail);}
   }} finally {SetupDiDestroyDeviceInfoList(set);}
   if(paths.Count!=1)throw new InvalidOperationException("Expected exactly one native VAIO control interface.");
   string path=paths[0];
   if(!path.StartsWith(@"\\?\root#media#",StringComparison.OrdinalIgnoreCase)||path.IndexOf(InterfaceGuid.ToString(),StringComparison.OrdinalIgnoreCase)<0)throw new InvalidOperationException("Unexpected VAIO control interface path.");
   var handle=CreateFile(path,0xc0000000,1,IntPtr.Zero,3,0x800,IntPtr.Zero);
   if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
   return handle;
  }
  static byte[] Query(SafeFileHandle handle) {
   byte[] input=new byte[16],output=new byte[416];uint count;
   if(!DeviceIoControl(handle,0x222050,input,16,output,416,out count,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());
   if(count!=416)throw new InvalidOperationException("Unexpected VAIO status buffer size: "+count);
   return output;
  }
  public static bool GetVolumeControl(){using(var h=Open()){return (Query(h)[0x174]&2)!=0;}}
  public static bool SetVolumeControl(bool enabled){using(var h=Open()){
   Query(h);byte[] input=BitConverter.GetBytes(enabled?1:0),output=new byte[4];uint count;
   if(!DeviceIoControl(h,0x222058,input,4,output,4,out count,IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());
   if(count!=4)throw new InvalidOperationException("Unexpected VAIO option result buffer size: "+count);
   bool actual=(Query(h)[0x174]&2)!=0;
   if(actual!=enabled)throw new InvalidOperationException("VAIO native volume option did not read back.");
   return actual;
  }}
 }
}
'@
}

function Get-DriverOptionsTargets {
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'This verified driver option implementation requires 64-bit Windows.' }
    @(
        [pscustomobject]@{View='Registry32';Path='SOFTWARE\VB-Audio\MultiCable'},
        [pscustomobject]@{View='Registry64';Path='SOFTWARE\VB-Audio\MultiCable'},
        [pscustomobject]@{View='Registry64';Path='SYSTEM\CurrentControlSet\Services\VB-MultiCable'}
    )
}

function Get-DriverOptionsRuntime {
    Initialize-DriverOptionsNative
    [LanAudioBridge.DriverOptions.Native]::GetVolumeControl()
}

function Set-DriverOptionsRuntime {
    param([bool]$Enabled)
    Initialize-DriverOptionsNative
    [LanAudioBridge.DriverOptions.Native]::SetVolumeControl($Enabled)
}

function Get-DriverVolumeControlState {
    param([Parameter(Mandatory)][string]$ControlPanelPath)
    Assert-DriverOptionsPanel $ControlPanelPath
    Initialize-DriverOptionsNative
    $values = @(foreach ($target in Get-DriverOptionsTargets) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $target.View)
        $key = $null
        try {
            $key = $base.OpenSubKey($target.Path, $false)
            $exists = $null -ne $key -and $key.GetValueNames() -contains $script:ValueName
            [pscustomobject]@{
                View = $target.View
                Path = $target.Path
                Exists = $exists
                Kind = $(if ($exists) { $key.GetValueKind($script:ValueName).ToString() } else { $null })
                Value = $(if ($exists) { $key.GetValue($script:ValueName) } else { $null })
            }
        } finally {
            if ($key) { $key.Dispose() }
            $base.Dispose()
        }
    })
    [pscustomobject]@{
        Schema = 1
        ControlPanelHash = $script:PanelHash
        ValueName = $script:ValueName
        RuntimeEnabled = Get-DriverOptionsRuntime
        Registry = $values
    }
}

function Assert-DriverOptionsSnapshot {
    param($Snapshot)
    if ($Snapshot.Schema -ne 1 -or $Snapshot.ControlPanelHash -cne $script:PanelHash -or
        $Snapshot.ValueName -cne $script:ValueName -or $Snapshot.RuntimeEnabled -isnot [bool]) {
        throw 'Invalid VAIO option snapshot.'
    }
    $targets = @(Get-DriverOptionsTargets)
    if (@($Snapshot.Registry).Count -ne $targets.Count) { throw 'Invalid VAIO option target count.' }
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $row = $Snapshot.Registry[$i]
        if ($row.View -cne $targets[$i].View -or $row.Path -cne $targets[$i].Path -or $row.Exists -isnot [bool]) {
            throw 'Invalid VAIO option target.'
        }
        if ($row.Exists -and ($row.Kind -cne 'DWord' -or $null -eq $row.Value -or
            [long]$row.Value -lt 0 -or [long]$row.Value -gt 1)) {
            throw 'Unsupported existing VAIO volume option type or value.'
        }
    }
}

function Assert-DriverOptionsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Administrator rights are required to persist the native VAIO volume option.'
        }
    } finally { $identity.Dispose() }
}

function Write-DriverOptionsRegistryValue {
    param($Target,[bool]$Exists,[int]$Value)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $Target.View)
    $key = $null
    try {
        $key = $base.OpenSubKey($Target.Path, $true)
        if ($Exists) {
            if (-not $key) { throw 'Expected VAIO registry key is missing; refusing to create an unrelated installation.' }
            $key.SetValue($script:ValueName, $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
        } elseif ($key) {
            $key.DeleteValue($script:ValueName, $false)
        }
    } finally {
        if ($key) { $key.Dispose() }
        $base.Dispose()
    }
}

function Restore-DriverVolumeControlState {
    param([Parameter(Mandatory)][string]$ControlPanelPath,[Parameter(Mandatory)]$Snapshot)
    Assert-DriverOptionsPanel $ControlPanelPath
    Assert-DriverOptionsSnapshot $Snapshot
    Assert-DriverOptionsAdministrator
    Initialize-DriverOptionsNative
    foreach ($row in $Snapshot.Registry) {
        Write-DriverOptionsRegistryValue $row $row.Exists ([int]$row.Value)
    }
    $null = Set-DriverOptionsRuntime $Snapshot.RuntimeEnabled
    $after = Get-DriverVolumeControlState $ControlPanelPath
    if (($after | ConvertTo-Json -Depth 6 -Compress) -cne ($Snapshot | ConvertTo-Json -Depth 6 -Compress)) {
        throw 'VAIO option rollback readback did not match its snapshot.'
    }
    return $after
}

function Enable-DriverWindowsVolumeControl {
    param([Parameter(Mandatory)][string]$ControlPanelPath,[Parameter(Mandatory)][string]$BackupPath)
    Assert-DriverOptionsAdministrator
    $before = Get-DriverVolumeControlState $ControlPanelPath
    Assert-DriverOptionsSnapshot $before
    if (-not [IO.Path]::IsPathRooted($BackupPath)) { throw 'An absolute backup file path is required.' }
    # CreateNew prevents overwriting the only rollback evidence on a retry.
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($before | ConvertTo-Json -Depth 6))
    $file = [IO.File]::Open($BackupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) }
    finally { $file.Dispose() }
    try {
        foreach ($row in $before.Registry) { Write-DriverOptionsRegistryValue $row $true 1 }
        $null = Set-DriverOptionsRuntime $true
        $after = Get-DriverVolumeControlState $ControlPanelPath
        if (-not $after.RuntimeEnabled -or @($after.Registry | Where-Object {
            -not $_.Exists -or $_.Kind -cne 'DWord' -or $_.Value -ne 1
        }).Count) { throw 'VAIO volume option persistence did not read back.' }
        [pscustomobject]@{ Before = $before; After = $after; BackupPath = $BackupPath; RestartRequired = $false }
    } catch {
        $failure = $_.Exception.Message
        try { $null = Restore-DriverVolumeControlState $ControlPanelPath $before }
        catch { throw ($failure + ' Rollback failed: ' + $_.Exception.Message + ' Backup: ' + $BackupPath) }
        throw ($failure + ' Original VAIO option state was restored.')
    }
}

Export-ModuleMember -Function Get-DriverVolumeControlState,Enable-DriverWindowsVolumeControl,Restore-DriverVolumeControlState
