# Renegade LAN verification attempt

Measured on 2026-11-06 on this machine. The goal was the step `03-renegade-lan.md`
lists as outstanding: two clients joining the shipped LAN host, a match played, one
client disconnecting.

**Two things were established and one was not.** The client's start-up failure is
solved and explained (it needs Steam at the same administrator integrity level). The
LAN discovery failure is now explained at packet level: the shipped dedicated server
*announces* itself to UDP port 3373 and never answers a client query — re-tested at
wire level with a receiving socket, which saw zero frames come back to it. No client joined, so `lan` stays `IMPLEMENTATION IN
PROGRESS` and no `verification` block is written.

Raw output and screenshots are under `docs/preservation/data/renegade-lan-verify/`
(git-ignored).

## Part 1 — the exit, and what fixed it

Every earlier attempt failed the same way: Steam started `Renegade.exe`, which started
`Game.dat`, and both were gone in about four seconds with exit code 0, no window, no
Windows Error Reporting record and no configuration written. Eight launch paths were
measured (Steam URL, the stub and `Game.dat` directly, unelevated and elevated, with
and without Steam's environment, with and without the XP compatibility layer, and
after the shipped configurator wrote valid settings). Elevation was necessary —
`Game.dat` is refused with error 740 from an ordinary process — but never sufficient.

The missing variable was the **integrity level of Steam itself**. `Game.dat` links
`steam_api.dll`, so its licence handshake runs against the Steam client; when Steam
runs as a normal user and the game runs elevated, the two sides are at different
integrity levels.

Measured: Steam was shut down cleanly (8 processes to 0) and restarted from an
elevated launcher — confirmed by parentage, `steam.exe` pid 20508 with
`ParentProcessId = 13844` (the elevated driver). `steam.exe -applaunch 2229890` from
that client is recorded in Steam's own log as `Game process added : AppID 2229890
"…\Renegade.exe", ProcID 15732`, and the chain then **survives**:
`Renegade.exe` 15732 → `Game.dat` 12428 → `WWConfig.exe` 14968. Accepting the shipped
configurator (client 296,441) closes it and `Game.dat` comes up with a window titled
"Renegade": intro, main menu, multiplayer screens, alive for 18 minutes.

Screenshots: `nav-01` (main menu), `nav-09`/`nav-12` (multiplayer screens).

## Part 2 — why the LAN list stays empty (packet-level)

The dedicated server reports a healthy host in its own console
(`srv-01-console.png`): `Initializing LAN Mode`, `Channel created OK`, `Loading level
C&C_Field.mix`, `Level loaded OK`, `LAN mode active`, `0/16 players`.

The exchange was captured with `pktmon` (NDIS-level, so it sees same-host traffic that
a raw socket bound to an interface does not) over an 8-second window while the
recorded client query was replayed — `pktmon-discovery.txt`, converted to
`pktmon-discovery.utf8.txt`:

| Frames | Flow | Payload |
| --- | --- | --- |
| **66** | `192.168.56.1:3373 → 255.255.255.255:3373` | 88 bytes, ~8 per second |
| **6** | `192.168.56.1:50240 → 255.255.255.255:3373` | 26 bytes (the client's query, 3 sends × in/out) |
| **0** | anything addressed to the querier's port (`:50240`) | — |
| **0** | anything on 4848 | — |

So the server's LAN discovery is **announcement-only** at this level: it broadcasts to
port 3373 about eight times a second, and the query is not answered. The first capture
could not distinguish "no answer was sent" from "an answer was dropped by the firewall",
so the reply channel was re-tested at wire level with the host running and a single
socket that could both broadcast and receive, querying from an ephemeral port
(`pktmon-reply.etl`, converted to `pktmon-reply.utf8.txt`):

| Frames | Flow |
| --- | --- |
| 72 | `192.168.56.1:3373 → 255.255.255.255:3373`, 88 bytes — the beacons |
| 6 | `192.168.56.1:52232 → 255.255.255.255:3373`, 26 bytes — the query |
| **0** | any frame to `:52232`, in either direction |

The querying socket also reported `replies: 0`. Nothing was dropped: no answer was ever
put on the wire. **The query → reply channel does not exist in this build.**

**What the client itself listens on is not settled.** The previous pass recorded
`0.0.0.0:52477` for the client "on the LAN Game List", and this pass could not
reproduce it: the client must be measured while demonstrably on that screen, synthetic
menu input did not register (Part 3), and `Get-NetUDPEndpoint` cannot list an elevated
process's sockets from a normal shell — which invalidates any sample taken that way.
The verdict below therefore does not depend on that number.
### The corrected bind test

An earlier pass reported that 3373 could not be shared and attributed that to exclusive
ownership, but its test used `System.Net.Sockets.UdpClient`, which sets
`ExclusiveAddressUse = true` on Windows, so `SO_REUSEADDR` never took effect and the
result proved nothing about the server's socket. `tools/scratch/beacon-listen.ps1` redoes
it properly: a raw socket with `ExclusiveAddressUse = false`, `SO_REUSEADDR` and
`SO_BROADCAST`, all set **before** `Bind(0.0.0.0:3373)`. Two runs, saved as
`bind-test-port-free.json` and `bind-test-port-held.json`:

| Host | Bind 3373 (shared mode) | Datagrams received |
| --- | --- | --- |
| stopped, 3373 free | **ok** | **1** — the 26-byte query from `192.168.56.1:55034`, hex `00 00 09 00 44 00 45 00 53 00 4b 00 54 00 4f 00 50 00 2d 00 32 00 00 00 89 00` |
| running, FDS holds 3373 | **FAILED** — WSAEACCES "forbidden by its access permissions", on both the first and a second socket | none — the port could not be taken |

So the mechanism itself is sound: a socket on 3373 **does** receive local broadcast
traffic byte-identically, which is exactly what a LAN client needs. What fails is
coexistence. On Vista and later a second bind with `SO_REUSEADDR` succeeds only if the
*first* socket set it too, and the shipped server does not. 3373 is also not in an
excluded Windows port range (`netsh int ipv4 show excludedportrange protocol=udp` starts
at 50000), so this is the server's own socket and not an OS reservation.

Both possible client behaviours lead to the same dead end. If the client listens on 3373
it cannot coexist with the host at all, because the port cannot be shared or moved. If it
listens on any other port it cannot hear beacons addressed to 3373, and it cannot receive
a reply either, because none is sent. A local relay cannot break the tie: receiving those
beacons requires the very port the server holds, so the relay would have to run the
server, not beside it.

**The port cannot be moved on this build.** The host tool honours `-Port`
(`Server.ini` was written with `Port = 3374`, confirmed) but `Server.dat` still bound
`0.0.0.0:3373`: LAN mode ignores the port setting. So 3373 is fixed and exclusive for
as long as the host runs.

This also explains why the earlier firewall work was irrelevant: the frames never left
the machine's own stack, and adding inbound UDP rules changed nothing (measured, then
removed).

## Part 3 — what was not achieved, and why

No client joined, so there is no join, no second instance, no gameplay, no disconnect,
and `LAN VERIFIED` is not written. Driving the game's menus also stayed unreliable:
the game reads relative mouse motion and draws its own cursor, so absolute cursor
placement does not move it. Two harness geometry bugs were found and fixed (window
rect versus client rect, and desktop versus window origin for relative motion), which
is why navigation worked at all, but it is not a foundation for playing a match. This
run never left the main menu: clicks and keys sent through the elevated driver left the
screen byte-identical, so one screenshot after another shows the same menu.

`client-endpoints.json` records the client elevated and running: at the main menu it
holds **no UDP or TCP endpoints at all**, and no process other than the dedicated server
ever owned 3373 in any run. The LAN-list reading could not be taken this pass, so the
earlier `52477` figure is withdrawn rather than reused.

**No working LAN path was demonstrated on this hardware.** The honest statement is:
the protocol shape (beacons to a fixed port 3373) implies two *separate hosts* each own
their own 3373 and could discover each other — but that is an inference from the
capture, not a measurement, and this machine cannot test it.

## What this does not prove

* Anything about two physical machines. Everything ran on one host.
* That LAN play is broken in general; only that co-located client and server cannot
  complete discovery, and why.
* Anything about anti-cheat or publisher multiplayer services — the LAN path uses
  neither.
* Anything about another build: the profile pins build `17427416` and specific binary
  hashes.

## What a future attempt needs

1. **A second host** (a second PC on the same subnet). Each host then owns its own
   UDP 3373, which is the configuration the beacon protocol expects. Re-run with
   `tools/scratch/probe-3373.ps1` on the client machine to confirm it receives the
   88-byte beacons before touching the game UI.
2. **Or a way to give the client its own 3373** on one machine. Windows offers none
   here: the port is held by a socket that does not set `SO_REUSEADDR`, so neither a
   second listener nor a beacon relay can take it (measured, above).
3. The client start prerequisite stays: **Steam and the game at the same administrator
   integrity level**, and the shipped configurator accepted once.
4. Menu driving would need hardware-level input; the game ignores absolute cursor
   placement.

## State left behind

Everything the test perturbed was reverted and verified:

* LAN host stopped; its junction and generated directory removed; the installation's
  `Data` folder still holds its original 35 files with no `svrcfg_lan.ini` written
  into it.
* No `Renegade`, `Game.dat`, `WWConfig` or server processes left; no listener on 3373.
* Two temporary inbound UDP rules were removed earlier in the attempt and are still
  absent.
* Render settings back to the originals: `RenderDeviceDepth=16`,
  `RenderDeviceWindowed=0`.
* Compatibility layers unchanged (`WINXPSP3` on the Renegade binaries, as found).
* Steam restarted normally, unelevated.

## Harness built for this attempt

In `tools/scratch/` (deliberately not shipped tools — they exist to drive a GUI and to
probe a protocol):

* `lan-driver.ps1` + `lan-driver-launch.ps1` + `lan-send.ps1` — an elevated
  request/response host: `launch` (arguments + environment), `adopt`, `focus`, `click`,
  `aimclick` (relative-motion aiming), `key`, `shot`, `info`, `kill`, `list`, `exit`.
  It refuses to act on any window it did not launch or adopt.
* `focus-shot.ps1` — foreground + screenshot for the non-elevated server console.
* `probe-3373.ps1` — listens on 3373 in the server's place and records what the client
  sends (this is what established the 26-byte query and its ~1/s cadence).
* `query-reply.ps1` — sends the client's exact 26-byte query from a socket that can
  also receive, and reports every datagram that comes back.
* `capture-query-reply.ps1` — the elevated pktmon capture around that query, so
  "no answer sent" is distinguishable from "answer dropped".
* `sample-client-endpoints.ps1` — records a running client's UDP/TCP endpoints; must
  run elevated because the client is elevated.
* `beacon-listen.ps1` — the corrected shared-port listener: `ExclusiveAddressUse`,
  `SO_REUSEADDR` and `SO_BROADCAST` before bind, one or two sockets, optional broadcast
  query, JSON out. This produced the two rows above.
* `query-3373.ps1` — replays that exact query at the live server.
* `capture-discovery.ps1` — the pktmon capture used for the table above.
* `lan-firewall.ps1`, `restore-lan-test.ps1` — temporary rules and full rollback.

`sniff-udp.ps1` (raw socket, `SIO_RCVALL`) captured nothing: same-host traffic does not
reach an interface-bound raw socket. `pktmon` does, which is why the capture above is
authoritative.

## Tool bug fixed while doing this

`Start-RenegadeLanHost.ps1 -Status` failed with *"Cannot convert value
System.Management.Automation.PSCustomObject to type
System.Management.Automation.SwitchParameter"*. PowerShell variables are
case-insensitive, so `$status = Get-RenegadeLanHostStatus …` was assigning an object
to the `[switch]$Status` parameter itself. The local is now `$hostStatus`; `-Status`
was verified both with no host and against a live host.
