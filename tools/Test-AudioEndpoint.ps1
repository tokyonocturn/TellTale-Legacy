#Requires -Version 5.1
<#
.SYNOPSIS
    Renders a test tone straight to a named audio endpoint and measures what the endpoint does with it.

.DESCRIPTION
    Opens the endpoint with WASAPI in shared mode, writes a sine wave for a few seconds and
    reads the endpoint's own peak meter. This separates "the application never reached this
    device" from "the device accepts audio and renders nothing".

    Read-only with respect to system configuration: it changes no default device, no volume
    and no routing. It only plays a tone.

.PARAMETER Name
    Substring of the endpoint's friendly name, for example '100027813'.

.PARAMETER Seconds
    How long the tone runs.

.PARAMETER Frequency
    Tone frequency in hertz.

.PARAMETER Amplitude
    Peak amplitude, 0..1.
#>
[CmdletBinding()]
param(
    [string]$Name = '100027813',
    [double]$Seconds = 6,
    [double]$Frequency = 440,
    [double]$Amplitude = 0.5,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WasapiTone {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        int GetDevice(string id, out IMMDevice device);
        int RegisterEndpointNotificationCallback(IntPtr client);
        int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        int OpenPropertyStore(int access, out IPropertyStore properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out int count);
        int GetAt(int index, out PROPERTYKEY key);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        int Commit();
    }

    [StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public int pid; }
    [StructLayout(LayoutKind.Explicit)] public struct PROPVARIANT {
        [FieldOffset(0)] public short vt;
        [FieldOffset(8)] public IntPtr pointerValue;
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient {
        int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        int GetBufferSize(out int frames);
        int GetStreamLatency(out long latency);
        int GetCurrentPadding(out int padding);
        int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        int GetMixFormat(out IntPtr format);
        int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr eventHandle);
        int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioRenderClient {
        int GetBuffer(int frames, out IntPtr buffer);
        int ReleaseBuffer(int frames, int flags);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        int GetPeakValue(out float peak);
    }

    [StructLayout(LayoutKind.Sequential)] public struct WAVEFORMATEX {
        public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec;
        public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample;
        public ushort cbSize;
    }

    static string PropString(IPropertyStore store, int pid) {
        var key = new PROPERTYKEY();
        key.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
        key.pid = pid;
        PROPVARIANT value;
        if (store.GetValue(ref key, out value) != 0) { return null; }
        if (value.vt == 31 && value.pointerValue != IntPtr.Zero) { return Marshal.PtrToStringUni(value.pointerValue); }
        return null;
    }

    public static Dictionary<string, object> Run(string match, double seconds, double frequency, double amplitude) {
        var report = new Dictionary<string, object>();
        var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDeviceCollection collection;
        int hr = enumerator.EnumAudioEndpoints(0 /*eRender*/, 1 /*DEVICE_STATE_ACTIVE*/, out collection);
        report["enumHr"] = hr;
        int count;
        collection.GetCount(out count);
        report["activeRenderEndpoints"] = count;

        IMMDevice device = null;
        string chosen = null;
        for (int i = 0; i < count; i++) {
            IMMDevice candidate;
            collection.Item(i, out candidate);
            IPropertyStore store;
            candidate.OpenPropertyStore(0, out store);
            string friendly = PropString(store, 14);   // PKEY_Device_FriendlyName
            string desc = PropString(store, 2);
            if (friendly != null && (friendly.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0
                                     || (desc != null && desc.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0))) {
                device = candidate;
                chosen = friendly;
                break;
            }
        }
        report["device"] = chosen;
        if (device == null) { report["error"] = "no endpoint matched"; return report; }

        string id;
        device.GetId(out id);
        report["id"] = id;
        int state;
        device.GetState(out state);
        report["state"] = state;

        IAudioMeterInformation endpointMeter = null;
        object meterObj;
        Guid meterIid = typeof(IAudioMeterInformation).GUID;
        if (device.Activate(ref meterIid, 1 /*CLSCTX_ALL*/, IntPtr.Zero, out meterObj) == 0) {
            endpointMeter = (IAudioMeterInformation)meterObj;
        }

        object clientObj;
        Guid clientIid = typeof(IAudioClient).GUID;
        hr = device.Activate(ref clientIid, 1, IntPtr.Zero, out clientObj);
        report["activateHr"] = hr;
        if (hr != 0) { report["error"] = "device activation failed 0x" + hr.ToString("X8"); return report; }
        var client = (IAudioClient)clientObj;

        IntPtr mixFormat;
        client.GetMixFormat(out mixFormat);
        var format = (WAVEFORMATEX)Marshal.PtrToStructure(mixFormat, typeof(WAVEFORMATEX));
        report["sampleRate"] = format.nSamplesPerSec;
        report["channels"] = format.nChannels;
        report["bitsPerSample"] = format.wBitsPerSample;

        hr = client.Initialize(0 /*shared*/, 0, 1000000, 0, mixFormat, IntPtr.Zero);
        report["initializeHr"] = hr;
        if (hr != 0) { report["error"] = "Initialize failed 0x" + hr.ToString("X8"); return report; }

        int frames;
        client.GetBufferSize(out frames);
        report["bufferFrames"] = frames;

        object renderObj;
        Guid renderIid = typeof(IAudioRenderClient).GUID;
        hr = client.GetService(ref renderIid, out renderObj);
        report["serviceHr"] = hr;
        if (hr != 0) { report["error"] = "GetService failed 0x" + hr.ToString("X8"); return report; }
        var renderer = (IAudioRenderClient)renderObj;

        hr = client.Start();
        report["startHr"] = hr;
        if (hr != 0) { report["error"] = "Start failed 0x" + hr.ToString("X8"); return report; }

        int channels = format.nChannels;
        double phase = 0;
        double step = 2 * Math.PI * frequency / format.nSamplesPerSec;
        var end = DateTime.UtcNow.AddSeconds(seconds);
        long framesWritten = 0;
        float peakMax = 0;
        int polls = 0;
        while (DateTime.UtcNow < end) {
            int padding;
            client.GetCurrentPadding(out padding);
            int available = frames - padding;
            if (available <= 0) { System.Threading.Thread.Sleep(5); continue; }

            IntPtr buffer;
            if (renderer.GetBuffer(available, out buffer) != 0) { break; }
            // 16-bit or 32-bit float mix format: write float for 32-bit, short otherwise.
            if (format.wBitsPerSample == 32) {
                var samples = new float[available * channels];
                for (int f = 0; f < available; f++) {
                    float value = (float)(Math.Sin(phase) * amplitude);
                    phase += step;
                    for (int c = 0; c < channels; c++) { samples[f * channels + c] = value; }
                }
                Marshal.Copy(samples, 0, buffer, samples.Length);
            } else {
                var bytes = new short[available * channels];
                for (int f = 0; f < available; f++) {
                    short value = (short)(Math.Sin(phase) * amplitude * short.MaxValue);
                    phase += step;
                    for (int c = 0; c < channels; c++) { bytes[f * channels + c] = value; }
                }
                Marshal.Copy(bytes, 0, buffer, bytes.Length);
            }
            renderer.ReleaseBuffer(available, 0);
            framesWritten += available;

            if (endpointMeter != null) {
                float peak;
                if (endpointMeter.GetPeakValue(out peak) == 0) {
                    if (peak > peakMax) { peakMax = peak; }
                    polls++;
                }
            }
            System.Threading.Thread.Sleep(10);
        }

        client.Stop();
        report["framesWritten"] = framesWritten;
        report["endpointPeak"] = peakMax;
        report["meterPolls"] = polls;
        report["verdict"] = peakMax > 0.001
            ? "endpoint meters the tone it was given"
            : "endpoint accepted the stream and metered nothing";
        return report;
    }
}
'@

$result = [WasapiTone]::Run($Name, $Seconds, $Frequency, $Amplitude)
$json = $result | ConvertTo-Json -Depth 3
if ($OutputPath) {
    $full = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $full -Value $json -Encoding UTF8
}
$json

$endpointExit = if ($result.ContainsKey('error')) { 2 }
                 elseif ($result.ContainsKey('verdict') -and $result['verdict'] -like '*meters the tone*') { 0 }
                 else { 3 }
exit $endpointExit
