#Requires -Version 5.1
<#
.SYNOPSIS
    Reports Windows render endpoints and their live peak levels.

.DESCRIPTION
    Enumerates render endpoints through Core Audio (IMMDeviceEnumerator), reads each
    endpoint's friendly name, state and current peak value, and resolves the target
    endpoint by name. Peak levels are per device, so a non-zero peak on the target
    with silence elsewhere is evidence that a process's audio actually reached it.

    Read-only: no endpoint, setting or default device is changed.

.PARAMETER TargetName
    Substring of the endpoint friendly name to resolve (default '100027813').

.PARAMETER Samples
    How many measurements to take.

.PARAMETER SampleMilliseconds
    Delay between measurements.

.PARAMETER OutputPath
    Optional JSON report path.

.PARAMETER AsJson
    Emit the report as JSON on stdout instead of a table.
#>
param(
    [string]$TargetName = '100027813',
    [int]$Samples = 1,
    [int]$SampleMilliseconds = 400,
    [string]$OutputPath = '',
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not ('TelltaleAudio.AudioProbe' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace TelltaleAudio
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct PROPERTYKEY { public Guid fmtid; public int pid; }

    // Native PROPVARIANT is 24 bytes on x64 (2-byte vt + 6 reserved + a 16-byte
    // union). The trailing pointer pads the union: without it the runtime writes
    // past this struct and corrupts the heap on the next allocation.
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT
    {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr p;
        public IntPtr p2;
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
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
    public interface IAudioMeterInformation
    {
        int GetPeakValue(out float peak);
        int GetMeteringChannelCount(out int channelCount);
        int GetChannelsPeakValues(int channelCount, [Out] float[] peakValues);
        int QueryHardwareSupport(out int hardwareSupportMask);
    }

    public class EndpointInfo
    {
        public string Id;
        public string Name;
        public int State;
        public bool IsDefaultConsole;
        public float Peak;
    }

    public static class AudioProbe
    {
        static readonly Guid IID_IAudioMeterInformation = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
        static readonly PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY
        {
            fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"),
            pid = 14
        };

        static string ReadString(IPropertyStore store)
        {
            PROPVARIANT value;
            PROPERTYKEY key = PKEY_Device_FriendlyName;
            int hr = store.GetValue(ref key, out value);
            if (hr != 0) return string.Empty;
            if (value.vt != 31) return string.Empty; // VT_LPWSTR
            return Marshal.PtrToStringUni(value.p) ?? string.Empty;
        }

        public static List<EndpointInfo> EnumerateRenderEndpoints()
        {
            var result = new List<EndpointInfo>();
            IMMDeviceEnumerator enumerator;
            try { enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject()); }
            catch (Exception ex) { throw new Exception("stage=enumerator-create: " + ex.Message); }
            if (enumerator == null) throw new Exception("stage=enumerator-create: null");
            IMMDeviceCollection collection;
            // eRender = 0, DEVICE_STATE_ACTIVE = 1
            int hr = enumerator.EnumAudioEndpoints(0, 1, out collection);
            if (hr != 0) throw new COMException("stage=enum-endpoints: EnumAudioEndpoints failed", hr);
            if (collection == null) throw new Exception("stage=enum-endpoints: null collection (hr=" + hr + ")");

            string defaultId = null;
            IMMDevice def;
            if (enumerator.GetDefaultAudioEndpoint(0, 0, out def) == 0 && def != null)
            {
                def.GetId(out defaultId);
            }

            int count;
            collection.GetCount(out count);
            for (int i = 0; i < count; i++)
            {
                IMMDevice device;
                int itemHr = collection.Item(i, out device);
                if (itemHr != 0 || device == null) continue;

                var info = new EndpointInfo();
                device.GetId(out info.Id);
                device.GetState(out info.State);
                info.IsDefaultConsole = defaultId != null && string.Equals(info.Id, defaultId, StringComparison.OrdinalIgnoreCase);

                IPropertyStore store;
                if (device.OpenPropertyStore(0, out store) == 0 && store != null)
                {
                    info.Name = ReadString(store);
                }

                result.Add(info);
                object meterObject;
                Guid iid = IID_IAudioMeterInformation;
                if (device.Activate(ref iid, 1, IntPtr.Zero, out meterObject) == 0 && meterObject != null)
                {
                    var meter = (IAudioMeterInformation)meterObject;
                    float peak;
                    if (meter.GetPeakValue(out peak) == 0) info.Peak = peak;
                }
            }
            return result;
        }
    }
}
'@
}

$measurements = @()
for ($i = 0; $i -lt $Samples; $i++) {
    $endpoints = [TelltaleAudio.AudioProbe]::EnumerateRenderEndpoints()
    $measurements += ,$endpoints
    if ($i -lt ($Samples - 1)) { Start-Sleep -Milliseconds $SampleMilliseconds }
}

$latest = $measurements[$measurements.Count - 1]
$rows = foreach ($endpoint in $latest) {
    $values = @()
    foreach ($sample in $measurements) {
        $match = $sample | Where-Object { $_.Id -eq $endpoint.Id } | Select-Object -First 1
        if ($match) { $values += [double]$match.Peak }
    }
    [pscustomobject]@{
        Name        = $endpoint.Name
        State       = if ($endpoint.State -eq 1) { 'active' } else { "state=$($endpoint.State)" }
        Default     = $endpoint.IsDefaultConsole
        PeakMax     = if ($values.Count -gt 0) { [Math]::Round(($values | Measure-Object -Maximum).Maximum, 6) } else { 0 }
        Id          = $endpoint.Id
    }
}

$target = @($rows | Where-Object { $_.Name -like "*$TargetName*" })
$targetActive = @($target | Where-Object { $_.State -eq 'active' })

if ($AsJson -or $OutputPath) {
    $report = [pscustomobject]@{
        SchemaVersion       = 1
        GeneratedUtc        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
        TargetName          = $TargetName
        SampleCount         = $Samples
        TargetMatchCount    = $target.Count
        TargetActiveCount   = $targetActive.Count
        TargetPeakMax       = if ($targetActive.Count -gt 0) { ($targetActive | Measure-Object -Property PeakMax -Maximum).Maximum } else { 0 }
        Endpoints           = @($rows)
    }
    $json = $report | ConvertTo-Json -Depth 5
    if ($OutputPath) {
        $full = if ([System.IO.Path]::IsPathRooted($OutputPath)) { [System.IO.Path]::GetFullPath($OutputPath) }
                else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputPath)) }
        $dir = Split-Path -Parent $full
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json | Set-Content -LiteralPath $full -Encoding UTF8
        if (-not $AsJson) { Write-Host ("Report: {0}" -f $full) }
    }
    if ($AsJson) { $json }
} else {
    $rows | Select-Object Name, State, Default, PeakMax | Format-Table -AutoSize
}

if (-not $AsJson) {
    Write-Host ("Target '{0}': {1} match(es), {2} active" -f $TargetName, $target.Count, $targetActive.Count)
    foreach ($match in $targetActive) {
        Write-Host ("  active: {0}  peakMax={1}  id={2}" -f $match.Name, $match.PeakMax, $match.Id)
    }
}

if ($targetActive.Count -eq 0) {
    [Console]::Error.WriteLine("Target endpoint '$TargetName' has no active render endpoint.")
    exit 2
}
exit 0
