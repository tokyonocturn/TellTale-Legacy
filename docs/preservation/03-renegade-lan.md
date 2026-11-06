# Renegade LAN host

First implementation milestone of the preservation program: local multiplayer for
Command & Conquer: Renegade using **only what the installation already ships**.

## Why Renegade

Renegade is the one target whose shipped files already contain the server:
`RenegadeFDS/` holds `RenegadeServer.exe`, `Server.dat`, `Server.ini`,
`GameSpy.ini` and `RenRem.exe`. Its `Server.ini` documents three modes:

```
; GameType =
;  Set this to WOL for a Westwood Online dedicated server.
;  Set this to GameSpy for a GameSpy mode dedicated server.
;  Set this to LAN for a LAN mode dedicated server.
```

LAN mode needs no nickname, password, serial or login server. The measured
server console confirms the mode it enters: `Initializing LAN Mode`.

## Design

```
%LOCALAPPDATA%\GamePreservation\renegade-lan\
├── host\                         generated, deleted on stop
│   ├── RenegadeServer.exe        copy of the shipped stub
│   ├── RenegadeServer.lcf        copy of the launcher config
│   ├── Server.dat                copy of the shipped payload
│   ├── Server.ini                generated: GameType = LAN
│   ├── svrcfg_lan.ini            generated: map cycle from installed maps
│   ├── banlist.txt, Scripts.dll, BandTest.dll, binkw32.dll, mss32.dll
│   └── Data  →  junction to <install>\Data
├── logs\                         captured stdout/stderr
└── host.json                     recorded state (pids, ports, hashes)
```

Three rules hold the design together:

1. **Nothing is written into the installation.** The generated settings files live
   in the host directory; the game's `Data` folder is exposed read-only through a
   **junction**, which needs no elevation (unlike a symlink) and is removed with
   `rmdir`, which cannot delete the target's contents.
2. **The build is verified before anything runs.** The dedicated server's SHA-256
   is compared with the profile; a mismatch refuses the launch.
3. **The state directory may not be inside the installation.** Enforced before any
   directory is created.

## Problems found and fixed while building it

Each of these was a real failure observed on this machine, not a precaution:

| Symptom | Cause | Fix |
| --- | --- | --- |
| Modal dialog `Launcher config file missing`, server never starts | The Steam-edition stub reads a `.lcf` next to it (`RUN=server.dat`, plus two SKU registry keys) | Copy `RenegadeServer.lcf` into the host directory |
| Modal dialog `Server.dat - System Error` | The stub runs `Server.dat` as a **separate process**, and that payload imports `BandTest.dll`, `binkw32.dll`, `mss32.dll` from the game root | Parse the payload's imports and copy every one that resolves inside the installation |
| `Error - server settings file 'data\svrcfg_lan.ini' not found - aborting` | `Config` is resolved relative to the map directory, i.e. `data\<Config>` | Generate `Config = ..\svrcfg_lan.ini`, so the settings file stays in the host directory instead of being written through the junction |
| `Map cycling is enabled but there are no maps in the cycle` | A settings file with `MapName=` alone is invalid | Generate `MapName00..NN` from the `C&C_*.mix` files actually installed |
| Map cycle still ignored after adding the keys | My generator concatenated the here-string's last line with the first cycle entry, and wrote LF line endings; the 2002-era parser expects CRLF | Build both INIs as explicit line lists and emit CRLF (`ConvertTo-CrlfText`) |
| Invoking shell never returned although the host was up | A GUI-subsystem child started from a console keeps the caller's handles open | Launch through `Win32_Process.Create` with `cmd.exe` carrying the log redirection, then locate the stub by image path |
| Recorded PID exited while the server kept running | The stub hands off to `Server.dat` | Track and record the whole process tree, sample every PID's UDP endpoints, and sweep by image path on stop |

## Measured run (2026-11-06)

```
LAN host started for cnc-renegade-steam-2229890
  mode      : LAN (no Westwood Online login, no serial)
  pid       : 20404
  Data      : junction -> D:\SteamLibrary\steamapps\common\Command & Conquer Renegade\Data
  hash check: matched profile
  udp       : 0.0.0.0:3373
  udp       : 127.0.0.1:63999
  udp       : 192.168.56.1:4848
  window    : Renegade Master Server - DESKTOP-2 - ..\svrcfg_lan.ini
```

The server's own console reported, in order:

```
Renegade Free Dedicated Server v1.038 L 2.0 Console mode active
*** Auto starting game. Type 'quit' to abort ***
Initializing LAN Mode
Applying server settings
Channel created OK
Loading level C&C_Field.mix
Load 100% complete
Level loaded OK
```

Observations that matter:

* The game port is **UDP 3373** on `0.0.0.0`, chosen by the server (`Port = 0`).
  `4848` is the GameSpy query port, `63999` a loopback admin/query socket.
* **No TCP connections** were held by any process in the tree (`netstat -ano -p TCP`
  matched none of the recorded PIDs) — no WOL login, no account.
* The console logs `Error processing HeartBeat List: <master.gamespy.com:27900,
  master.udpsoft.com:27900>` and falls back to that default list. In LAN mode no
  heartbeat is sent (nothing appeared on TCP and the host does not register), but
  the message is recorded here rather than hidden: it is the server's own default,
  not something this program configured.
* Stopping removed the junction and the host directory, left no processes running,
  and the installation's `Data` folder still contained exactly its original 35
  files with no `svrcfg_lan.ini` written into it.

## What this does and does not prove

**Proved:** the shipped dedicated server starts in LAN mode from generated
configuration, binds its game port, creates a channel and loads a map, with the
installation unmodified and the run fully reversible.

**Not proved — and therefore not claimed:**

* That a Renegade **client can see and join** this host. The client now starts (it
  needs Steam running at the same administrator integrity level as the game), but
  discovery between a client and the server **on the same machine** cannot complete:
  a packet capture shows the server announcing itself 88 bytes at a time to
  `255.255.255.255:3373` about eight times a second and never answering the client's
  query — re-tested at wire level with a receiving socket, which saw not one frame
  addressed back to it. A corrected shared-port bind
  test (raw socket, `ExclusiveAddressUse=false` and `SO_REUSEADDR` set before bind)
  takes 3373 and receives broadcast bytes while the host is stopped, but is refused
  while the host runs — the server's socket does not permit sharing — and LAN mode
  ignores `Port`, so a co-located process cannot listen where the beacons go. See
  [05-renegade-lan-verify.md](05-renegade-lan-verify.md) for both bind results, the
  capture table and the server console output.
* That a match can be **played** to completion and that a client disconnect is
  handled.
* That the same procedure works on any other build. The profile pins build
  `17427416` and the server hash; a different build must be re-inventoried.

## Commands

```powershell
# start (default: LAN mode, first installed map, server port chosen by the server)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-RenegadeLanHost.ps1

# what is running, on which ports
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Start-RenegadeLanHost.ps1 -Status

# stop and remove the generated host directory (logs are kept)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Stop-RenegadeLanHost.ps1
```

## Rollback

`Stop-RenegadeLanHost.ps1` is the rollback: it stops the recorded process tree,
removes the junction with `rmdir`, deletes the generated host directory and keeps
`last-run-server.*.log` under the state root. Deleting
`%LOCALAPPDATA%\GamePreservation\renegade-lan` afterwards removes the evidence
too. The installation is never touched, so there is nothing else to revert.

## Next steps

1. **Test discovery across two hosts, which is the configuration the protocol
   expects.** The capture settled what happens on one machine: 66 beacons to
   `255.255.255.255:3373` in eight seconds, 6 client queries, and not one packet
   addressed back to the querier. Beacons are addressed to a fixed port that only
   the sender can hold here (a shared-mode bind is refused, measured), and LAN mode
   ignores `Port`, so the only way to test the intended topology is a second PC on
   the same subnet. Run `tools/scratch/probe-3373.ps1` — or `beacon-listen.ps1`, which
   has already shown that a 3373 socket receives local broadcast bytes intact — on
   that machine first: if it receives the 88-byte beacons, the client has something to
   list.
2. Join from a client and play a match — the step that converts this from "host
   measured" to `LAN VERIFIED`.
3. Drive the client with hardware-level input. The game tracks relative mouse motion
   and draws its own cursor, so absolute cursor placement does not move it and menu
   clicks are unreliable.

Findings from the attempt that matter here: the client starts only when **Steam runs
at the same administrator integrity level** as `Game.dat` (whose sibling carries
`requireAdministrator`); the client's settings live in
`HKLM\SOFTWARE\WOW6432Node\Westwood\Renegade` (machine-wide, administrator needed)
and nothing is written to `Documents\Renegade` or `HKCU\Software\Westwood`; and the
game runs its own `WWConfig.exe` on a first start, which has to be accepted before
the game continues.
