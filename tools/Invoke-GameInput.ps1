#Requires -Version 5.1
<#
.SYNOPSIS
    Sends real mouse and keyboard input to the game window.

.DESCRIPTION
    Drives the game the way a person at the keyboard does: foregrounding its window,
    moving the system cursor and pressing keys through SendInput. Nothing here reads
    or writes game memory, patches files, or scripts the engine - it is UI automation
    of a human-equivalent click path.

    Client coordinates are relative to the game's client area, converted with
    ClientToScreen so window borders and position do not shift the target.

.PARAMETER Action
    Info       report the window rectangle, client origin and foreground state.
    Foreground bring the game window to the foreground.
    Click      left click at (X, Y).
    Drag       press at (X, Y), move to (ToX, ToY), release (held clicks, mouse look).
    Key        press and release one key.
    KeyDown    hold a key.
    KeyUp      release a key.
    Hold       hold a key or the left mouse button for Milliseconds, then release.
    Capture    save the window as a PNG.

.PARAMETER Key
    Key name: letters A-Z, digits 0-9, SPACE, ENTER, ESC, TAB, arrows, SHIFT, CTRL.
#>
[CmdletBinding()]
param(
    [ValidateSet('Info', 'Foreground', 'Look', 'Click', 'Press', 'Drag', 'Key', 'KeyDown', 'KeyUp', 'Hold', 'Capture')]
    [string]$Action = 'Info',
    [int]$X = 0,
    [int]$Y = 0,
    [int]$ToX = 0,
    [int]$ToY = 0,
    [string]$Key = '',
    [int]$Milliseconds = 400,
    [int]$OwnerPid = 0,
    [string]$OutputPath,
    [ValidateSet('Screen', 'Window')]
    [string]$CaptureMethod = 'Screen'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class GameInputNative {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint INPUT_KEYBOARD = 1;

    public static void SendKeyCode(ushort vk, bool up) {
        INPUT[] one = new INPUT[1];
        one[0].type = INPUT_KEYBOARD;
        one[0].u.ki.wVk = vk;
        one[0].u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
        if (up) { one[0].u.ki.dwFlags = KEYEVENTF_KEYUP; }
        SendInput(1, one, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

function Get-GameVirtualKey {
    <#
    .SYNOPSIS
        Maps a key name to its Windows virtual-key code.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $upper = $Name.ToUpperInvariant()
    $named = @{
        'SPACE' = 0x20; 'ENTER' = 0x0D; 'ESC' = 0x1B; 'ESCAPE' = 0x1B; 'TAB' = 0x09
        'UP' = 0x26; 'DOWN' = 0x28; 'LEFT' = 0x25; 'RIGHT' = 0x27
        'SHIFT' = 0x10; 'CTRL' = 0x11; 'ALT' = 0x12
        'F1' = 0x70; 'F5' = 0x74; 'F9' = 0x78
    }
    if ($named.ContainsKey($upper)) { return [uint16]$named[$upper] }
    if ($upper -match '^[A-Z]$') { return [uint16][char]$upper }
    if ($upper -match '^[0-9]$') { return [uint16][char]$upper }
    throw "Unsupported key name: $Name"
}

function Get-GameWindow {
    <#
    .SYNOPSIS
        Returns the main window handle for the game process, refusing when absent.
    #>
    param([int]$ProcessId = 0)

    $proc = if ($ProcessId -ne 0) {
        Get-Process -Id $ProcessId -ErrorAction Stop
    } else {
        Get-Process -Name 'WalkingDead101' -ErrorAction Stop | Select-Object -First 1
    }
    if ($proc.MainWindowHandle -eq [IntPtr]::Zero) {
        throw "Process $($proc.Id) has no main window handle"
    }
    $proc
}

function Get-ClientPoint {
    <#
    .SYNOPSIS
        Converts game client coordinates to absolute screen coordinates.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$WindowHandle,
        [Parameter(Mandatory)][int]$ClientX,
        [Parameter(Mandatory)][int]$ClientY
    )

    $point = New-Object GameInputNative+POINT
    $point.X = $ClientX
    $point.Y = $ClientY
    [void][GameInputNative]::ClientToScreen($WindowHandle, [ref]$point)
    [pscustomobject]@{ X = $point.X; Y = $point.Y }
}

function Move-GameCursor {
    param([IntPtr]$WindowHandle, [int]$ClientX, [int]$ClientY)

    $screen = Get-ClientPoint -WindowHandle $WindowHandle -ClientX $ClientX -ClientY $ClientY
    [void][GameInputNative]::SetCursorPos($screen.X, $screen.Y)
    Start-Sleep -Milliseconds 120
    $screen
}

function Enable-GameForeground {
    param([IntPtr]$WindowHandle)

    [void][GameInputNative]::SetForegroundWindow($WindowHandle)
    Start-Sleep -Milliseconds 300
    $fg = [GameInputNative]::GetForegroundWindow()
    $fgPid = [uint32]0
    [void][GameInputNative]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    [pscustomobject]@{ Foreground = ($fg -eq $WindowHandle); ForegroundPid = $fgPid }
}

# Functions above stay testable: dot-sourcing the file defines them without driving input.
if ($MyInvocation.InvocationName -eq '.') { return }

$proc = Get-GameWindow -ProcessId $OwnerPid
$hwnd = $proc.MainWindowHandle
$windowRect = New-Object GameInputNative+RECT
[void][GameInputNative]::GetWindowRect($hwnd, [ref]$windowRect)
$clientRect = New-Object GameInputNative+RECT
[void][GameInputNative]::GetClientRect($hwnd, [ref]$clientRect)
$origin = New-Object GameInputNative+POINT
[void][GameInputNative]::ClientToScreen($hwnd, [ref]$origin)

switch ($Action) {
    'Info' {
        $fg = [GameInputNative]::GetForegroundWindow()
        $fgPid = [uint32]0
        [void][GameInputNative]::GetWindowThreadProcessId($fg, [ref]$fgPid)
        [pscustomobject]@{
            Pid = $proc.Id
            Hwnd = $hwnd.ToInt64()
            WindowLeft = $windowRect.Left
            WindowTop = $windowRect.Top
            Width = $windowRect.Right - $windowRect.Left
            Height = $windowRect.Bottom - $windowRect.Top
            ClientWidth = $clientRect.Right - $clientRect.Left
            ClientHeight = $clientRect.Bottom - $clientRect.Top
            ClientOriginX = $origin.X
            ClientOriginY = $origin.Y
            ForegroundPid = $fgPid
            IsForeground = ($fgPid -eq $proc.Id)
            Title = $proc.MainWindowTitle
        }
    }
    'Foreground' {
        Enable-GameForeground -WindowHandle $hwnd
    }
    'Look' {
        # Move the pointer without clicking: the engine turns the camera from mouse movement.
        [void](Enable-GameForeground -WindowHandle $hwnd)
        $screen = Move-GameCursor -WindowHandle $hwnd -ClientX $X -ClientY $Y
        "looked to client=($X,$Y) screen=($($screen.X),$($screen.Y))"
    }
    'Click' {
        [void](Enable-GameForeground -WindowHandle $hwnd)
        $screen = Move-GameCursor -WindowHandle $hwnd -ClientX $X -ClientY $Y
        [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 90
        [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
        "clicked client=($X,$Y) screen=($($screen.X),$($screen.Y))"
    }
    'Press' {
        # Click and hold at one point, for hold-to-walk or hold-to-interact prompts.
        [void](Enable-GameForeground -WindowHandle $hwnd)
        $point = Move-GameCursor -WindowHandle $hwnd -ClientX $X -ClientY $Y
        [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds $Milliseconds
        [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
        "pressed client=($X,$Y) screen=($($point.X),$($point.Y)) for ${Milliseconds}ms"
    }
    'Drag' {
        [void](Enable-GameForeground -WindowHandle $hwnd)
        $from = Move-GameCursor -WindowHandle $hwnd -ClientX $X -ClientY $Y
        [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 80
        $steps = 8
        for ($i = 1; $i -le $steps; $i++) {
            $cx = [int]($X + (($ToX - $X) * $i / $steps))
            $cy = [int]($Y + (($ToY - $Y) * $i / $steps))
            [void](Move-GameCursor -WindowHandle $hwnd -ClientX $cx -ClientY $cy)
        }
        Start-Sleep -Milliseconds 80
        [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
        "dragged ($X,$Y) -> ($ToX,$ToY)"
    }
    'Key' {
        [void](Enable-GameForeground -WindowHandle $hwnd)
        $vk = Get-GameVirtualKey -Name $Key
        [GameInputNative]::SendKeyCode($vk, $false)
        Start-Sleep -Milliseconds 60
        [GameInputNative]::SendKeyCode($vk, $true)
        "pressed $Key"
    }
    'KeyDown' {
        [void](Enable-GameForeground -WindowHandle $hwnd)
        [GameInputNative]::SendKeyCode((Get-GameVirtualKey -Name $Key), $false)
        "down $Key"
    }
    'KeyUp' {
        [void](Enable-GameForeground -WindowHandle $hwnd)
        [GameInputNative]::SendKeyCode((Get-GameVirtualKey -Name $Key), $true)
        "up $Key"
    }
    'Hold' {
        [void](Enable-GameForeground -WindowHandle $hwnd)
        if ($Key) {
            $vk = Get-GameVirtualKey -Name $Key
            [GameInputNative]::SendKeyCode($vk, $false)
            Start-Sleep -Milliseconds $Milliseconds
            [GameInputNative]::SendKeyCode($vk, $true)
            "held $Key for ${Milliseconds}ms"
        } else {
            [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds $Milliseconds
            [GameInputNative]::mouse_event([GameInputNative]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
            "held mouse button for ${Milliseconds}ms"
        }
    }
    'Capture' {
        if (-not $OutputPath) { throw 'Capture requires -OutputPath' }
        $full = [System.IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $full
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $width = $windowRect.Right - $windowRect.Left
        $height = $windowRect.Bottom - $windowRect.Top
        $bmp = New-Object System.Drawing.Bitmap $width, $height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        if ($CaptureMethod -eq 'Window') {
            # PrintWindow needs PW_RENDERFULLCONTENT (0x2) for DirectX surfaces.
            $hdc = $gfx.GetHdc()
            $printed = [GameInputNative]::PrintWindow($hwnd, $hdc, 2)
            $gfx.ReleaseHdc($hdc)
        } else {
            [void](Enable-GameForeground -WindowHandle $hwnd)
            $gfx.CopyFromScreen($windowRect.Left, $windowRect.Top, 0, 0, $bmp.Size)
            $printed = $true
        }
        $gfx.Dispose()
        $bmp.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        [pscustomobject]@{ Path = $full; Width = $width; Height = $height; Method = $CaptureMethod; Captured = $printed }
    }
}

