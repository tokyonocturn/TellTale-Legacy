# Online dependency map

Everything here was read out of the installed binaries (ASCII and UTF-16 string
scans plus PE import tables). No runtime capture is recorded yet, so this file
distinguishes **binary evidence** from **runtime behaviour**, which is still
unmeasured for every title.

## Classification rules

* `mandatory` — the profile asserts the feature cannot work without it; used by
  `Test-GameOfflineReadiness.ps1` to block a verdict.
* `optional` — reached from a menu, a statistics call, advertising or patching.
* `BLOCKED` — mandatory and with no lawful replacement.

## Per title

### C&C: Generals and Zero Hour

Evidence: literal hostnames in `Game.dat` (not in the `.bind`-wrapped launcher).

| Service | Endpoint | Mandatory | Affects | Replacement |
| --- | --- | --- | --- | --- |
| GameSpy master/lobby | `gpcm.gamespy.com`, `gpsp.gamespy.com` | no | online multiplayer, lobby | Generals Online (`playgenerals.online`); Revora retired Generals/Zero Hour from C&C:Online in 2026 |
| GameSpy stats / advertising | `gamestats.gamespy.com` (`/ccgenerals/`, `/ccgenzh/`), `d.gamespy.com`, `launch.gamespyarcade.com` | no | stats, ads, store links | none needed |

Both titles ship PunkBuster (`P2XDLL.DLL`), which matters to any future
multiplayer claim.

### C&C: Renegade

Evidence: literal hostnames in `Game.exe` (link date 2000-06-01).

| Service | Endpoint | Mandatory | Affects | Replacement |
| --- | --- | --- | --- | --- |
| GameSpy master | `master.gamespy.com:27900`, `master.udpsoft.com:27900` | no | internet server list | community listings (W3D Hub); LAN mode needs none |
| Westwood Online ("mangler") | `mangler.westwood.com`, `mangler1..3.westwood.com` | no | WOL login, quick match, ladder | XWIS (EA redirect, 2005); not used in LAN mode |
| MOTD / version check / store | `motd.gamespy.com`, `www.gamespyarcade.com`, `www.fileplanet.com`, `www.ea.com` | no | news ticker, version check | none needed |

The shipped dedicated server documents `GameType = LAN`, which skips all three.
That is what [03-renegade-lan.md](03-renegade-lan.md) implements.

### C&C 3: Tiberium Wars and Kane's Wrath

Evidence: `cnc3game.dat` / `cnc3ep1.dat`; launchers add `servserv`.

| Service | Endpoint | Mandatory | Affects | Replacement |
| --- | --- | --- | --- | --- |
| GameSpy SDK (auth, presence, peerchat) | `gpcm.gamespy.com`, `gpsp.gamespy.com`, `peerchat.gamespy.com`, `sake.gamespy.net`, `cc3tibwars.auth.pubsvs.gamespy.com` / `cc3xp1.auth.pubsvs.gamespy.com` | no | online multiplayer, lobby, chat, ranked stats | Revora C&C:Online (Tacitus), still operating for both titles in 2026 |
| EA FESL | `cnc3-pc.fesl.ea.com`, `fesl.ea.com`, `messaging.ea.com` | no | EA account login, entitlements | none claimed |
| EA servserv | `servserv.generals.ea.com/servserv/cnc3`, `.../cnc3_ep1` | no | patch check, news | none needed |
| GameSpy advertising | `d.gamespy.com`, `ingamead.gamespy.com` | no | advertising | none needed |

The two titles have **different GameSpy product paths** (`cc3tibwars` vs
`cc3xp1`), so they are profiled separately and a fix for one is not assumed to
work for the other.

### C&C 4: Tiberian Twilight — blocked

| Service | Endpoint | Mandatory | Affects |
| --- | --- | --- | --- |
| EA Blaze | `launcher.support.blaze.com`, `rts.eala.ea.com/launcher.support/` | **yes** | account, progression, unlocks, every mode |
| EA patch delivery | `downloads.cdn.commandandconquer.com/.../patchlink.xml` | no | patching |
| Vivox voice | not resolved statically (`vivoxsdk.dll`, `vivoxplatform.dll` ship in `Data`) | no | voice chat |

The launcher is a .NET assembly that only imports `mscoree.dll`; progression is
server-side. Neither Revora nor the projects it lists replaces Blaze, so the
honest status is `BLOCKED BY EXTERNAL DEPENDENCY`. Nothing here attempts to
defeat an account system.

### Friday the 13th: The Game — multiplayer blocked

The executable links only Windows networking (`WS2_32`, `WINHTTP`, `WININET`);
the service configuration lives in packaged UE4 data. The publisher's remaining
online services were shut down on **2024-12-31**, and no dedicated-server binary
exists in the depots. A fan project (Friday the 13th: Resurrected) was stopped by
a cease-and-desist in 2024.

Preserved surface: Offline Bots, Single Player Challenges and the Virtual Cabin,
all shipped. EasyAntiCheat is present and is not bypassed.

### Plants vs. Zombies GOTY

| Service | Endpoint | Mandatory | Affects |
| --- | --- | --- | --- |
| PopCap registration/news | `www.popcap.com/register.php?thegame=`, `beta.popcap.com`, `www.popcap.com` | no | registration prompt, news |

The only endpoint strings in the executable are these, reached from an optional
menu action. No campaign or save path references them.

### Plants vs. Zombies: Replanted

`Replanted.exe` is a Unity stub importing only `KERNEL32.dll` and
`UnityPlayer.dll`; the only string found is a `microsoft.windows.com` URL. The
managed game code is IL2CPP inside `GameAssembly.dll` (83 MB), which has **not**
been analysed yet — so this title is `INVENTORY COMPLETE`, not
`DEPENDENCIES DOCUMENTED`.

### SimCity 3000 Unlimited

| Service | Endpoint | Mandatory | Affects |
| --- | --- | --- | --- |
| SimCity exchange and chat | `www.simcity.com:6667` (IRC), `.../exchange/`, `.../cityfiles.html`, `.../primarymap.ini`, `.../tickeradvertisements.html` | no | exchange, chat, ads |

A dial-up-era service that no longer exists. The simulation and local city saves
do not use it. The installed build is GOG-packaged inside Steam.

### SimCity 4 Deluxe

No service endpoint: the only host-like string is `maxis.com`, used as text/help
link. `WININET` is imported for the in-game browser. The executable is
`.bind`-wrapped, so the negative result is weaker evidence than for an unwrapped
binary, and the profile says so.

### Need for Speed: Rivals

| Service | Endpoint | Mandatory | Affects | Replacement |
| --- | --- | --- | --- | --- |
| EA GOS redirector | `gosredirector.ea.com`, `gosredirector.online.ea.com`, `gosca.ea.com:44125/redirector` | no (online features) | AllDrive sessions, matchmaking | TurboRivals (unofficial; not used or verified here) |
| EA Blaze/telemetry | `peach.online.ea.com`, `elephant.online.ea.com/bugsentry`, `reports.tools.gos.ea.com/bugsentry` | no | telemetry, bug reports | none needed |
| EA activation | `Core/Activation64.dll`, `Core/Activation.dll` (endpoint not resolved) | **yes** | launch | none |

EA switched off Rivals' online services on **2025-10-07**. Solo AllDrive against
AI is a designed mode, but whether a fresh offline launch passes the activation
library is unmeasured, which is why the status is
`REVERSE ENGINEERING IN PROGRESS` rather than verified or blocked.

## Community landscape (researched, dated)

| Project | Scope | State (2026) | Used by this program |
| --- | --- | --- | --- |
| Revora C&C:Online (Tacitus) | TW, KW, RA3 online | operating; retired Generals/ZH in 2026 | not integrated; documented as an external option |
| Generals Online (`playgenerals.online`) | Generals, Zero Hour online | successor endorsed by Revora; parity claimed December 2025 | not integrated |
| RA3BattleNet | Red Alert 3 (CN community) | listed by Revora as current | not integrated; RA3 not installed |
| XWIS | Westwood Online replacement | operating since EA's 2005 redirect | not needed for LAN |
| W3D Hub | Renegade launcher/browser, TT patch | maintained | not required for the LAN host |
| Renegade X | standalone Unreal successor | operating | out of scope: not the original game |
| TurboRivals | Rivals AllDrive replacement | unofficial, reported 2026 | not used |
| Friday the 13th: Resurrected | F13 revival | halted by cease-and-desist (2024) | not used |

None of these is bundled, redistributed or silently depended on. Where a
replacement exists it is recorded as an option for the player, not as a
prerequisite this program installs.

## What is not established

No runtime capture exists yet for any title. Specifically unmeasured: whether an
offline launch stalls on `servserv` (TW/KW), whether Generals/ZH reach the main
menu with GameSpy unreachable, whether Rivals' activation gate blocks an offline
launch, and what F13 does after its backend disappeared. Those are measurement
tasks, not documentation tasks.
