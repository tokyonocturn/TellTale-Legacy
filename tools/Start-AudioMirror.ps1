#Requires -Version 5.1
<#
.SYNOPSIS
    Mirrors the audio rendered to one endpoint onto another endpoint.

.DESCRIPTION
    Opens the source endpoint in WASAPI loopback mode, captures the mix and re-renders it
    onto the target endpoint. This is a per-process compatibility shim used when a machine's
    per-application device routing is not honoured: the application keeps rendering to the
    system default (unchanged), and this process carries its audio to the endpoint that
    should receive it.

    Nothing about the system is reconfigured: no default device, no volumes, no registry
    policy. Stopping the process restores the previous behaviour exactly.

.PARAMETER SourceName
    Substring of the source endpoint's friendly name, for example 'Voicemeeter AUX'.

.PARAMETER TargetName
    Substring of the target endpoint's friendly name, for example '100027813'.

.PARAMETER Seconds
    How long to run.

.PARAMETER OutputPath
    Where to write the measurement JSON.

.PARAMETER Quiet
    Suppress the periodic one-line status output.
#>
[CmdletBinding()]
param(
    [string]$SourceName = 'Voicemeeter AUX',
    [string]$TargetName = '100027813',
    [int]$Seconds = 60,
    [string]$OutputPath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WasapiMirror {
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

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient {
        int GetBuffer(out IntPtr data, out int frames, out int flags, out long devicePosition, out long qpcPosition);
        int ReleaseBuffer(int frames);
        int GetNextPacketSize(out int frames);
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

    const int DEVICE_STATE_ACTIVE = 1;
    const int STREAMFLAGS_LOOPBACK = 0x00020000;

    static string PropString(IPropertyStore store, int pid) {
        var key = new PROPERTYKEY();
        key.fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
        key.pid = pid;
        PROPVARIANT value;
        if (store.GetValue(ref key, out value) != 0) { return null; }
        if (value.vt == 31 && value.pointerValue != IntPtr.Zero) { return Marshal.PtrToStringUni(value.pointerValue); }
        return null;
    }

    static IMMDevice Find(IMMDeviceCollection collection, int count, string match, List<string> seen, out string friendly) {
        friendly = null;
        for (int i = 0; i < count; i++) {
            IMMDevice candidate;
            collection.Item(i, out candidate);
            IPropertyStore store;
            candidate.OpenPropertyStore(0, out store);
            string name = PropString(store, 14);
            string desc = PropString(store, 2);
            if (name != null) { seen.Add(name); }
            if (name != null && (name.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0
                                 || (desc != null && desc.IndexOf(match, StringComparison.OrdinalIgnoreCase) >= 0))) {
                friendly = name;
                return candidate;
            }
        }
        return null;
    }

    public static Dictionary<string, object> Run(string sourceMatch, string targetMatch, int seconds,
                                                 Action<string> progress, out string error) {
        error = null;
        var report = new Dictionary<string, object>();
        var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDeviceCollection collection;
        enumerator.EnumAudioEndpoints(0, DEVICE_STATE_ACTIVE, out collection);
        int count;
        collection.GetCount(out count);

        var seen = new List<string>();
        string sourceFriendly, targetFriendly;
        IMMDevice source = Find(collection, count, sourceMatch, seen, out sourceFriendly);
        IMMDevice target = Find(collection, count, targetMatch, seen, out targetFriendly);
        report["source"] = sourceFriendly;
        report["target"] = targetFriendly;
        if (source == null) { error = "source endpoint not found"; return report; }
        if (target == null) { error = "target endpoint not found"; return report; }

        object srcClientObj;
        Guid clientIid = typeof(IAudioClient).GUID;
        int hr = source.Activate(ref clientIid, 1, IntPtr.Zero, out srcClientObj);
        if (hr != 0) { error = "source activate 0x" + hr.ToString("X8"); return report; }
        var srcClient = (IAudioClient)srcClientObj;
        IntPtr mixFormat;
        srcClient.GetMixFormat(out mixFormat);
        var fmt = (WAVEFORMATEX)Marshal.PtrToStructure(mixFormat, typeof(WAVEFORMATEX));
        report["sampleRate"] = fmt.nSamplesPerSec;
        report["channels"] = fmt.nChannels;
        report["bitsPerSample"] = fmt.wBitsPerSample;

        hr = srcClient.Initialize(0, STREAMFLAGS_LOOPBACK, 2000000, 0, mixFormat, IntPtr.Zero);
        report["captureInitializeHr"] = hr;
        if (hr != 0) { error = "loopback initialize 0x" + hr.ToString("X8"); return report; }

        object captureObj;
        Guid captureIid = typeof(IAudioCaptureClient).GUID;
        hr = srcClient.GetService(ref captureIid, out captureObj);
        report["captureServiceHr"] = hr;
        if (hr != 0) { error = "capture GetService 0x" + hr.ToString("X8"); return report; }
        var capture = (IAudioCaptureClient)captureObj;

        object tgtClientObj;
        hr = target.Activate(ref clientIid, 1, IntPtr.Zero, out tgtClientObj);
        if (hr != 0) { error = "target activate 0x" + hr.ToString("X8"); return report; }
        var tgtClient = (IAudioClient)tgtClientObj;
        hr = tgtClient.Initialize(0, 0, 2000000, 0, mixFormat, IntPtr.Zero);
        report["renderInitializeHr"] = hr;
        if (hr != 0) { error = "target initialize 0x" + hr.ToString("X8"); return report; }

        object renderObj;
        Guid renderIid = typeof(IAudioRenderClient).GUID;
        hr = tgtClient.GetService(ref renderIid, out renderObj);
        report["renderServiceHr"] = hr;
        if (hr != 0) { error = "render GetService 0x" + hr.ToString("X8"); return report; }
        var renderer = (IAudioRenderClient)renderObj;

        int targetBuffer;
        tgtClient.GetBufferSize(out targetBuffer);
        report["targetBufferFrames"] = targetBuffer;

        IAudioMeterInformation targetMeter = null;
        object meterObj;
        Guid meterIid = typeof(IAudioMeterInformation).GUID;
        if (target.Activate(ref meterIid, 1, IntPtr.Zero, out meterObj) == 0) {
            targetMeter = (IAudioMeterInformation)meterObj;
        }

        tgtClient.Start();
        srcClient.Start();

        int blockAlign = fmt.nBlockAlign;
        var end = DateTime.UtcNow.AddSeconds(seconds);
        long framesCaptured = 0, framesRendered = 0;
        double capturePeak = 0, targetPeak = 0;
        int silentPackets = 0, packets = 0;
        var lastReport = DateTime.UtcNow;

        while (DateTime.UtcNow < end) {
            int packetFrames;
            if (capture.GetNextPacketSize(out packetFrames) != 0 || packetFrames == 0) {
                System.Threading.Thread.Sleep(4);
                continue;
            }
            while (packetFrames > 0) {
                IntPtr data;
                int frames;
                int flags;
                long devPos, qpc;
                if (capture.GetBuffer(out data, out frames, out flags, out devPos, out qpc) != 0) { break; }
                packets++;

                // measure capture peak (first 4000 frames is enough for a level reading)
                if (fmt.wBitsPerSample == 32 && frames > 0) {
                    int sampleCount = Math.Min(frames * fmt.nChannels, 8192);
                    var buffer = new float[sampleCount];
                    Marshal.Copy(data, buffer, 0, sampleCount);
                    for (int i = 0; i < sampleCount; i++) {
                        double abs = Math.Abs(buffer[i]);
                        if (abs > capturePeak) { capturePeak = abs; }
                    }
                }
                if (flags != 0) { silentPackets++; }   // AUDCLNT_BUFFERFLAGS_SILENT

                // copy into the target, waiting for space
                int written = 0;
                while (written < frames) {
                    int padding;
                    tgtClient.GetCurrentPadding(out padding);
                    int space = targetBuffer - padding;
                    if (space <= 0) { System.Threading.Thread.Sleep(3); continue; }
                    int chunk = Math.Min(space, frames - written);
                    IntPtr targetBufferPtr;
                    if (renderer.GetBuffer(chunk, out targetBufferPtr) != 0) { break; }
                    IntPtr src = IntPtr.Add(data, written * blockAlign);
                    if (flags != 0) {
                        // silent packet: write zeros
                        byte[] zeros = new byte[chunk * blockAlign];
                        Marshal.Copy(zeros, 0, targetBufferPtr, zeros.Length);
                    } else {
                        byte[] bytes = new byte[chunk * blockAlign];
                        Marshal.Copy(src, bytes, 0, bytes.Length);
                        Marshal.Copy(bytes, 0, targetBufferPtr, bytes.Length);
                    }
                    renderer.ReleaseBuffer(chunk, 0);
                    written += chunk;
                }
                framesCaptured += frames;
                framesRendered += written;
                capture.ReleaseBuffer(frames);

                if (targetMeter != null) {
                    float peak;
                    if (targetMeter.GetPeakValue(out peak) == 0 && peak > targetPeak) { targetPeak = peak; }
                }
                if (capture.GetNextPacketSize(out packetFrames) != 0) { break; }
            }

            if (progress != null && (DateTime.UtcNow - lastReport).TotalSeconds >= 5) {
                lastReport = DateTime.UtcNow;
                progress(string.Format("captured {0} frames, capturePeak {1:F3}, targetPeak {2:F3}",
                                       framesCaptured, capturePeak, targetPeak));
            }
        }

        srcClient.Stop();
        tgtClient.Stop();

        report["seconds"] = seconds;
        report["framesCaptured"] = framesCaptured;
        report["framesRendered"] = framesRendered;
        report["packets"] = packets;
        report["silentPackets"] = silentPackets;
        report["capturePeak"] = capturePeak;
        report["targetPeak"] = targetPeak;
        report["verdict"] = targetPeak > 0.001
            ? "target endpoint metered the mirrored audio"
            : "target endpoint metered nothing although frames were rendered";
        return report;
    }
}
'@

$progressScript = {
    param($message)
    if (-not $Quiet) { Write-Host $message }
}.GetNewClosure()

$errorText = $null
$result = [WasapiMirror]::Run($SourceName, $TargetName, $Seconds, $progressScript, [ref]$errorText)
if ($errorText) { $result['error'] = $errorText }
$json = $result | ConvertTo-Json -Depth 4
if ($OutputPath) {
    $full = [System.IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $full
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $full -Value $json -Encoding UTF8
}
$json

$mirrorExit = if ($result.ContainsKey('error')) { 2 }
               elseif ($result.ContainsKey('verdict') -and $result['verdict'] -like '*metered the mirrored audio*') { 0 }
               else { 3 }
if ($mirrorExit -ne 0) { Write-Host "mirror result: $($result['verdict'])$($result['error'])" }
exit $mirrorExit
