#Requires -Version 5.1
<#
.SYNOPSIS
    Lists audio sessions per render endpoint with their owning process and peak.

.DESCRIPTION
    Endpoint peak meters only say that *something* reached a device. Session
    enumeration attributes audio to a process: each session carries a PID and can be
    queried through IAudioMeterInformation, so "this process is playing on device X"
    is a measurement rather than an inference.

    Read-only: sessions are inspected, never modified.

.PARAMETER ProcessName
    Optional process name filter (for example WalkingDead101).

.PARAMETER OutputPath
    Optional JSON report path.

.PARAMETER AsJson
    Emit JSON on stdout.
#>
param(
    [string]$ProcessName = '',
    [string]$OutputPath = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ('TelltaleAudio.SessionProbe' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace TelltaleAudio
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT
    {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr p;
        public IntPtr p2;   // pads the 16-byte union: native size is 24 bytes on x64
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IPropertyStore properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out int count);
        int GetAt(int index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        int Commit();
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioMeterInformation { int GetPeakValue(out float peak); }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISimpleAudioVolume
    {
        int SetMasterVolume(float level, IntPtr eventContext);
        int GetMasterVolume(out float level);
        int SetMute(bool mute, IntPtr eventContext);
        int GetMute(out bool mute);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionManager2
    {
        int GetAudioSessionControl(IntPtr audioSessionGuid, int flags, out IntPtr session);
        int GetSimpleAudioVolume(IntPtr audioSessionGuid, int flags, out IntPtr volume);
        int GetSessionEnumerator(out IAudioSessionEnumerator enumerator);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionEnumerator
    {
        int GetCount(out int count);
        int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionControl2
    {
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName(IntPtr name, IntPtr eventContext);
        int GetIconPath(out IntPtr path);
        int SetIconPath(IntPtr path, IntPtr eventContext);
        int GetGroupingParam(out Guid groupingParam);
        int SetGroupingParam(ref Guid groupingParam, IntPtr eventContext);
        int RegisterAudioSessionNotification(IntPtr newNotifications);
        int UnregisterAudioSessionNotification(IntPtr newNotifications);
        int GetSessionIdentifier(out IntPtr id);
        int GetSessionInstanceIdentifier(out IntPtr id);
        int GetProcessId(out uint processId);
        int IsSystemSoundsSession();
        int SetDuckingPreference(bool optOut);
    }

    public class SessionInfo
    {
        public string DeviceName;
        public string DeviceId;
        public uint ProcessId;
        public int State;
        public float Peak;
        public float Volume = -1f;
        public bool Muted;
    }

    public static class SessionProbe
    {
        static readonly Guid IID_IAudioSessionManager2 = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");
        static readonly PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY
        {
            fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
            pid = 14
        };

        static string ReadString(IPropertyStore store)
        {
            PROPVARIANT value;
            PROPERTYKEY key = PKEY_Device_FriendlyName;
            if (store.GetValue(ref key, out value) != 0) return string.Empty;
            if (value.vt != 31) return string.Empty;
            return Marshal.PtrToStringUni(value.p) ?? string.Empty;
        }

        public static List<SessionInfo> EnumerateSessions()
        {
            var result = new List<SessionInfo>();
            IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());

            IMMDeviceCollection collection;
            if (enumerator.EnumAudioEndpoints(0, 1, out collection) != 0 || collection == null) return result;

            int deviceCount;
            collection.GetCount(out deviceCount);
            for (int d = 0; d < deviceCount; d++)
            {
                IMMDevice device;
                if (collection.Item(d, out device) != 0 || device == null) continue;

                string deviceName = string.Empty;
                string deviceId;
                device.GetId(out deviceId);
                IPropertyStore store;
                if (device.OpenPropertyStore(0, out store) == 0 && store != null) deviceName = ReadString(store);

                object managerObject;
                Guid iid = IID_IAudioSessionManager2;
                if (device.Activate(ref iid, 1, IntPtr.Zero, out managerObject) != 0 || managerObject == null) continue;

                var manager = (IAudioSessionManager2)managerObject;
                IAudioSessionEnumerator sessionEnum;
                if (manager.GetSessionEnumerator(out sessionEnum) != 0 || sessionEnum == null) continue;

                int sessionCount;
                sessionEnum.GetCount(out sessionCount);
                for (int s = 0; s < sessionCount; s++)
                {
                    IAudioSessionControl2 control;
                    if (sessionEnum.GetSession(s, out control) != 0 || control == null) continue;

                    var info = new SessionInfo { DeviceName = deviceName, DeviceId = deviceId };
                    control.GetState(out info.State);
                    control.GetProcessId(out info.ProcessId);

                    if (control != null)
                    {
                        try
                        {
                            var meter = control as IAudioMeterInformation;
                            if (meter != null) { float peak; meter.GetPeakValue(out peak); info.Peak = peak; }
                            var volume = control as ISimpleAudioVolume;
                            if (volume != null)
                            {
                                float level; bool muted;
                                if (volume.GetMasterVolume(out level) == 0) info.Volume = level;
                                if (volume.GetMute(out muted) == 0) info.Muted = muted;
                            }
                        }
                        catch (InvalidCastException) { }
                    }
                    result.Add(info);
                }
            }
            return result;
        }
    }
}
'@
}

$sessions = [TelltaleAudio.SessionProbe]::EnumerateSessions()
$rows = foreach ($session in $sessions) {
    $name = ''
    if ($session.ProcessId -ne 0) {
        $proc = Get-Process -Id $session.ProcessId -ErrorAction SilentlyContinue
        if ($proc) { $name = $proc.ProcessName }
    } else {
        $name = '(system sounds)'
    }
    [pscustomobject]@{
        Process    = $name
        ProcessId  = $session.ProcessId
        Device     = $session.DeviceName
        State      = $session.State
        Peak       = [Math]::Round($session.Peak, 6)
        Volume     = [Math]::Round($session.Volume, 3)
        Muted      = $session.Muted
        DeviceId   = $session.DeviceId
    }
}

if ($ProcessName) {
    $rows = @($rows | Where-Object { $_.Process -eq $ProcessName })
}

$rows = @($rows | Sort-Object Device, Process)

if ($AsJson -or $OutputPath) {
    $report = [pscustomobject]@{
        SchemaVersion = 1
        GeneratedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
        Filter        = $ProcessName
        Count         = $rows.Count
        Sessions      = @($rows)
    }
    $json = $report | ConvertTo-Json -Depth 5
    if ($OutputPath) {
        $full = if ([System.IO.Path]::IsPathRooted($OutputPath)) { [System.IO.Path]::GetFullPath($OutputPath) }
                else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputPath)) }
        $dir = Split-Path -Parent $full
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json | Set-Content -LiteralPath $full -Encoding UTF8
        Write-Host ("Report: {0}" -f $full)
    }
    if ($AsJson) { $json }
} else {
    $rows | Select-Object Process, ProcessId, Device, State, Peak, Volume, Muted | Format-Table -AutoSize
}

exit 0
