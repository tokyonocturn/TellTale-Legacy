# Preservation program

This is the multi-game preservation program that grew out of the Telltale work in
`docs/rea/`. It does not replace that work: the Telltale profiles, tools and
findings remain where they were and keep their own tests and release process.

## Scope

The program investigates each owned installation separately, records what it
actually does without a network, and builds only the infrastructure that is
missing. It never bypasses Steam DRM, account systems or access controls, and it
never packages game code, assets or saves. Every tool here reads an installation
and writes only to a state directory or to the user's own save location.

## Operating modes

| Mode | Meaning | Evidence needed to claim it |
| --- | --- | --- |
| **A. Full offline** | The original game launches and is playable with no network, including saves and settings. | A measured launch, a played section, a save, a restart, and progress persisting — per title. |
| **B. Local network** | Two machines play together over LAN with no publisher matchmaking. | Two clients joined, a match played, and a disconnect handled. A listening host alone is not enough. |
| **C. Direct peer-to-peer** | Host/client connections without a central server. | A real connection between two peers plus failure handling. |

## Status vocabulary

The mission's statuses, plus one documented addition:

| Status | Meaning |
| --- | --- |
| `NOT INVESTIGATED` | In the registry, nothing measured. |
| `INVENTORY COMPLETE` | Files, executables and layout recorded; dependencies not yet analysed. |
| `REVERSE ENGINEERING IN PROGRESS` | Analysis started but incomplete (for example, code hidden behind Steam's `.bind` wrapper). |
| `DEPENDENCIES DOCUMENTED` | Every endpoint found statically is recorded and classified. Says nothing about runtime. |
| `IMPLEMENTATION IN PROGRESS` | A compatibility component exists but is not verified end to end. |
| `OFFLINE PARTIALLY FUNCTIONAL` | Some offline play works, something needed does not. |
| `OFFLINE VERIFIED` | Mode A evidence exists for the title's primary experience. |
| `LAN VERIFIED` | Mode B evidence exists. |
| `P2P VERIFIED` | Mode C evidence exists. |
| `FULL PRESERVATION VERIFIED` | The documented primary experience is preserved in every mode the game has. |
| `BLOCKED BY EXTERNAL DEPENDENCY` | Preservation needs a service that no longer exists and has no lawful replacement. |
| `NOT APPLICABLE` | **Addition to the mission list.** Used for LAN/P2P on titles that have no multiplayer; `NOT INVESTIGATED` would imply missing work that does not exist. Recorded in `registry/games.json` under `statusVocabularyNote`. |

Capabilities are tracked per mode, independently. No title is marked with a mode
it has not been measured in.

## Registry

`registry/games.json` is the single source of truth for what exists:

```json
{
  "schemaVersion": 1,
  "statusVocabulary": ["..."],
  "games": [
    {
      "id": "cnc-renegade-steam-2229890",
      "title": "Command & Conquer: Renegade",
      "steamAppId": 2229890,
      "steamBuildId": "17427416",
      "installDir": "Command & Conquer Renegade",
      "installed": true,
      "engine": "Westwood 3D (Renegade engine, 2002)",
      "adapter": "renegade-fds",
      "profile": "games/cnc-renegade-steam-2229890/profile.json",
      "capabilities": { "offline": "...", "lan": "...", "p2p": "..." }
    }
  ]
}
```

Steam libraries are resolved in this order: an explicit `-LibraryRoot`, the
`STEAM_LIBRARY` environment variable, the `libraryfolders.vdf` next to the
client, then the registry's `SteamPath`. `installed` is derived from the
manifest's `StateFlags` (bit 4), not from a directory existing.

## Profile schema (version 2)

One file per installed title, `games/<id>/profile.json`:

| Field | Content |
| --- | --- |
| `steam` | app id, manifest build id, install directory |
| `engine` | engine name, the evidence that identifies it, and what that implies |
| `binaries` | path, role, size, SHA-256, architecture, subsystem, link date, `.bind` presence, imports |
| `userState` | save/settings locations with the evidence for each, and whether it is verified on this machine |
| `dependencies` | service, endpoint, protocol, `mandatory`, what it affects, the evidence, community replacement if one exists |
| `capabilities` | per-mode status |
| `staticAnalysis` | method and, explicitly, what it could not see |

Older Telltale profiles (`profiles/<id>/profile.json`, schema 1) are untouched.
`adapter` in the registry names a game-specific component when one exists; today
only Renegade has one.

## Tools

| Tool | Purpose | Exit codes |
| --- | --- | --- |
| `Get-PreservationStatus.ps1` | Registry-wide table or JSON | 0 |
| `Get-PreservationInventory.ps1` | Per-title file, PE, import and endpoint inventory | 0 ok, 2 not installed/found |
| `Test-GameOfflineReadiness.ps1` | Fail-closed audit: install, build, binary hashes, user-state writability, mandatory dependencies | 0 no failures, 2 at least one failure |
| `Start-RenegadeLanHost.ps1` | Builds and starts the Renegade LAN host; `-Status`, `-Stop` | 0 listening, 2 refused/failed, 3 alive but not listening, 4 already running |
| `Stop-RenegadeLanHost.ps1` | Stops the host and removes its generated directory | 0 |
| `Preservation.Common.psm1` | Shared helpers: Steam manifests, PE reader, endpoint extraction, INI round trip, junctions, host lifecycle | n/a |

None of these tools writes to an installation. `Test-GameOfflineReadiness.ps1`
fails closed: a changed binary or a mandatory external dependency is a failure,
not a warning.

## Adding a game

1. Add a registry entry with `installed: false` and no profile if it is not on disk.
2. Run `Get-PreservationInventory.ps1 -GameId <id>` and record the measured facts.
3. Write `games/<id>/profile.json` from those facts — never from memory of the game.
4. Run `Test-GameOfflineReadiness.ps1 -GameId <id>`; fix the profile until it is `ready` or deliberately `blocked`.
5. Only then record a capability status above `DEPENDENCIES DOCUMENTED`.

## Evidence policy

Every report is written to `docs/preservation/data/`, which is git-ignored
because it contains absolute paths and machine state. Committed documentation
quotes measured values and marks anything unmeasured as unmeasured. A launch that
reaches a menu is not playability; a listening socket is not a LAN session.
