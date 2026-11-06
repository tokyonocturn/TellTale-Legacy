# REA 17 — Offline acceptance run (2026-11-06)

The first run of the game with the publisher endpoints actually unavailable. This is the
record of what was observed, including the parts that were awkward.

## Preconditions

| Item | Value |
|---|---|
| Game process | closed before the run |
| Saves backed up | `backups/20261106-050802-offline-acceptance` (12 files) and `backups/20261106-050701-pre-offline-acceptance` |
| Hosts file before | SHA-256 `4DA2C479D9A3774B99BF03CECBC1FD26F731816DF9D7BCF076663BB1782B6097` |
| Endpoints blocked | `api.telltalegames.com`, `meta.telltalegames.com` → `127.0.0.1` (marked block, verified through `-Action Status`) |
| Steam | running; the DRM gate was left untouched |

## Run 1 — cold launch through the harness

`tools/Test-OfflineLaunch.ps1` (elevated):

| Stage | Result |
|---|---|
| precondition / elevation | OK, no game running, elevated |
| save backup | `backups/20261106-050802-offline-acceptance` |
| block | OK — both domains → `127.0.0.1` |
| launch | OK — window `Telltale Games` appeared |
| observe | **11 frames, remote addresses: none** — no connection to any address, blocked or otherwise, during 90 s |
| offline isolation | OK |
| hosts rollback | OK — byte-identical to the pre-run hash |

The captured frames show the animated title screen reaching **`CLICK TO CONTINUE`**, with
the banner text "For the latest information on…" — the offline fallback banner, not the
live news feed.

Frames: `tools/scratch/offline-20261106-110802/` (git-ignored; frames are game art).

## Run 2 — offline save load, held across a fresh launch

The harness cannot play, so the save-load half was driven by hand with the block applied.

1. Block re-applied and verified (`-Action Status` → `Blocked: true`, both domains).
2. The running instance was **terminated rather than exited** — the frontend's `EXIT GAME`
   item did not accept clicks at this display size (tried y = 607, 620, 635, 650, 665 with
   no effect; the same failure shape as the earlier bar-coordinate problem). Saves were
   already backed up twice, and a clean exit + relaunch cycle had been observed earlier in
   the day, so terminating was an acceptable cost to force a genuine cold start. It is
   recorded here rather than glossed over.
3. Cold launch through `steam://rungameid/207610` → pid **6056**, window `Telltale Games`.
4. Drove the real frontend: click to continue → `PLAY` → `Game 1 / Episode 1` slot →
   `CONTINUE`.
5. The game loaded through the episode page and into **Episode 1's motor inn scene**
   (Lee, Clementine, Carley and Doug behind the truck, interaction chevrons live).

At the moment of that capture the game held **no remote TCP connection at all**:

```
Get-NetTCPConnection -OwningProcess 6056 | Where RemoteAddress not in (0.0.0.0, ::, 127.0.0.1, ::1)
→ (empty)
```

Evidence frames (git-ignored):
`off1` main menu offline, `off2`/`off3` slot list with the save recognised,
`offl3` episode page for the slot, `offl4` in-game at the motor inn.

## Rollback

`-Action Unblock` removed the marked block; the hosts file hash returned to
`4DA2C479D9A3774B99BF03CECBC1FD26F731816DF9D7BCF076663BB1782B6097`, **identical** to the
pre-run value. DNS resolved `api.telltalegames.com` back to its CloudFront addresses.

## What this run establishes

- The game **cold-launches with the publisher endpoints unreachable** and reaches its title
  screen and main menu.
- An **existing save loads offline**: the slot list is populated, the episode page renders,
  and the chapter loads into a live in-game scene.
- The block is **reversible to the byte**, and the game's own network use during those runs
  was **zero** — including the persistent API socket seen when the endpoints are reachable.

## What it does not establish

- **Episode 1's ending and credits** — the loaded scene is Episode 1's final chapter, but it
  was not played to the end in this run.
- **The Episode 1 → Episode 2 transition** offline.
- **Episodes 2–5** loading offline: they are installed but were not opened.
- **Dialogue choices, branching consequences and cinematics** offline: not exercised.
- **400 Days**: not installed on this machine, so it cannot be tested here.
- The forced termination in step 2 means this run did not itself exercise a *clean* exit
  followed by a cold start offline; that path was exercised separately with the network
  available.
