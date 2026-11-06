# REA 06: Preservation requirements and milestone status

## Requirements derived from the investigation

### R1: Licence and DRM stay intact (hard requirement)

`WalkingDead101.exe` contains a `.bind` Steam DRM section and requires
`SteamAPI_Init`. Preservation must work **with** Steam, never around it. Any
proposal that patches the executable, emulates Steam, or injects a licence is out
of scope and must be rejected in review.

### R2: Legitimate offline path must be documented and tested

Steam Offline Mode with a cached licence is the supported offline mechanism. The
project must state this plainly, verify the game works under it, and distinguish it
from "the game has no online features".

### R3: Publisher API failure must be survivable

Startup contacts `api.telltalegames.com`. Verified: the game reaches the main menu
with that host unreachable. Preservation must not depend on that service remaining
online, and must not attempt to substitute or impersonate it.

### R4: Saves must be recoverable

State is local, small and mutable at exit. Automated, hash-verified backup/restore
with a pre-restore safety copy is required before any compatibility experiment.

### R5: Version identity must be explicit

Different builds (Steam original, 400 Days bundle, Definitive Series, console
re-releases) must never share a profile. Every result is tied to an executable hash
plus Steam build id.

### R6: No proprietary content in the repository

No executables, archives, extracted assets, decrypted props, or personal saves.
Tools only read a user's own installation and write backups on that user's machine.

### R7: Claims must be testable

Every compatibility statement must point at a recorded session, a hash, or an
automated test. Distinguish "observed", "inferred" and "unknown".

## Milestone 1: complete

Delivered and verified on the target installation:

| Deliverable | Verification |
| --- | --- |
| Forensic inventory tool + report | `docs/rea/data/inventory.json`, 130 files hashed |
| Engine/version identification | PE analysis, PDB path, Lua 5.1.4, ttarch v9 |
| Startup sequence documented | Two recorded sessions + Steam logs |
| Online dependency identified | `api.telltalegames.com` via DNS cache + netstat |
| Offline startup verified | Main menu with endpoint blocked, 0 remote endpoints |
| Offline readiness audit | `tools/Test-OfflineReadiness.ps1`, verdict `ready` |
| Save backup/restore | 9 automated tests, incl. tamper rejection |
| Legal boundaries | `docs/legal-boundaries.md` |
| Reusable architecture | Profile-driven tools, engine family separate from build |

### What "verified" means here

* The menu screenshot in the offline run shows `PLAY / EPISODE STATUS / SETTINGS /
  EXIT GAME`.
* The session log for that run records `RemoteEndpoints: 0` and a single
  `127.0.0.1:443` attempt (the blackholed host).
* The readiness audit passed every check (build hash, archives, Steam manifest,
  DirectX runtime, save-directory writability).

### What is explicitly not verified

* Gameplay beyond the main menu (no new game, no dialogue, no episode transition).
* Save-slot creation through play.
* A full machine-offline run with Steam Offline Mode.
* Any build other than Steam app 207610 build 244978.
* Behaviour with a Telltale account signed in (no account UI was reachable).

## Milestone 2: planned

**Goal:** prove that a played session survives offline and a restart.

1. Drive a new game to the first save checkpoint (input automation or attended run),
   capture the resulting `.save` files and document their layout at the byte level
   without publishing content.
2. Verify choice persistence: make one branching choice, exit, relaunch offline,
   confirm the choice is reflected.
3. Verify episode transition from Episode 1 to Episode 2 in an offline session.
4. Add save-slot inspection to `Get-GameInventory`-style tooling (metadata only).
5. Record the prefs format delta across launches to confirm exit-time persistence.

## Milestone 3: planned

* Confirm archive mount order and patch precedence by observation.
* Document the ttarch v9 table layout (no asset extraction shipped).
* Full Steam Offline Mode run with evidence.
* Season 2 / 400 Days / Definitive Series profiles, each independently verified.

## Known risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Steam client update breaks old DRM | Game may stop launching | Document exact working client/branch; never patch |
| DirectX 9 runtime absent on clean machine | Game fails at launch | Document DXSETUP prerequisite; readiness audit warns |
| Save corruption on crash | Lost progress | Snapshot before each experiment |
| Telltale API shutdown | News/status degrade | Already survivable; verified |
| Confusing builds | Wrong conclusions | Hash + build-id gating in every profile |
