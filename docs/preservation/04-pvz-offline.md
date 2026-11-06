# PvZ GOTY: offline acceptance run

Measured on 2026-11-06 on this machine. This is the first title in the program to
reach `OFFLINE VERIFIED`. It exists to show what that claim is based on, including
where it stops.

The run is reproducible from the commands at the end. Raw output, screenshots and
save copies are under `docs/preservation/data/pvz-offline/` (git-ignored).

## Result

| Criterion | Result | Evidence |
| --- | --- | --- |
| Launched with the game blocked outbound | pass | two firewall rules, both enabled, before launch (`03-firewall.log`) |
| A section was played | pass | level 1-1 completed, Sunflower unlocked (`16-level-complete.png`) |
| A save was written | pass | three files, hashed (`18-save-artifacts/`) |
| Restarted still blocked, progress intact | pass | menu reads `LEVEL 1-2`, `Welcome back, PVZTest!` (`23-restart-menu.png`) |
| Installation unchanged | pass | `PlantsVsZombies.exe` `868f8e2b…`, `main.pak` `58783264…` before and after |
| No network activity from the game | pass | 0 TCP / 0 UDP at every sample (`04-session.log`) |

Status: **`OFFLINE VERIFIED`** for mode A, with the caveats at the end.

## How the network was blocked

`dir=out action=block profile=any` rules for the exact executable paths, installed
by one elevated session that removes them when the run signals completion — so no
rule can outlive the test. Domain, Private and Public firewall profiles were all
enabled, so the rules were live.

Two rules were needed, and the reason is the main finding of this run.

**The shipping executable is a wrapper.** A first attempt launched
`PlantsVsZombies.exe` directly and the game refused with `Unable to load Steam.dll`
(`05-direct-launch-failed.png`): direct launch without the Steam client cannot
start this build. Launched through Steam, the wrapper:

1. extracts the real game to `C:\ProgramData\PopCap Games\PlantsVsZombies\popcapgame1.exe` (3,557,760 bytes),
2. stages assets and saves under `C:\ProgramData\Steam\PlantsVsZombies` (171 files, 32,376,497 bytes),
3. runs `popcapgame1.exe`, and
4. deletes that executable again on exit, keeping the staged tree and the saves.

`popcapgame1.exe` is what owns the window and does the rendering, so blocking only
the installer's executable would have blocked the wrong process. Rules were
therefore installed for both paths, and every sample of the running game's
endpoints returned zero:

```
18:45  sample pid=16212 tcp=0 udp=0      (title screen)
18:49  sample pid=16212 tcp=0 udp=0      (level 1-1)
18:58  sample pid=22152 tcp=0 udp=0      (after restart)
19:02  sample pid=22152 tcp=0 udp=0      (before quit)
```

## What was played

Adventure was started from the main menu, a player name (`PVZTest`) was entered
(the game showed a new-user prompt, which matches the measured absence of any save
before the run), and the Steam Cloud dialog was declined so the save under test
would be the local file rather than a cloud copy.

Level 1-1 was played to completion: two peashooters planted, sun collected, the
single zombie killed, and the reward screen reported **"You got a new plant:
Sunflower"**. Clicking through started level 1-2, which loaded with a five-lane
lawn and the sunflower in the seed bank — so progression is real, not just a menu
state.

The mouse was driven by `tools/scratch/pvz-drive.ps1`, which refuses to click unless
the game owns the foreground and aborts on focus loss; sun collection used
`tools/scratch/pvz-autoplay.ps1`, a fast in-process click loop over the lawn. The
game pauses when it loses focus, which is why an interruption in the middle of the
run cost no game time.

## Where the save actually lives

The profile previously guessed `%APPDATA%\PopCap Games`. That directory never
appeared — measured absent before the run and still absent after a completed level.
The game writes to `C:\ProgramData\Steam\PlantsVsZombies\userdata`:

| File | Size | SHA-256 | Written when |
| --- | --- | --- | --- |
| `users.dat` | 23 B | `92695b312e536da5…` | first launch, player name entered |
| `user1.dat` | 888 B | `f9a20cc406fc37ea…` | level completion |
| `game1_0.dat` | 50,280 B | `0c5b7b3f52cff726…` | returning to the menu ("Your game will be saved") |

All three survived a normal quit with unchanged hashes, and survived a further
launch and close without being rewritten. Copies are kept in
`18-save-artifacts/`; nothing is redistributed, and the directory is git-ignored.

## Restart

After quitting from the menu, the game was launched again with both rules still
active. It started from the extracted `popcapgame1.exe`, re-read the local
`userdata` directory, and the main menu showed **`LEVEL 1-2`** and
**`Welcome back, PVZTest!`** — the state comes off the disk, not from the session.

The installation was then verified untouched: `PlantsVsZombies.exe`
`868f8e2b…` and `main.pak` `58783264…` match the pre-run hashes exactly. The only
thing removed from the machine was the wrapper's own extracted executable.

## What this does not prove

* **The Steam client was running and online.** The block covered the game's
  executables, not Steam, and direct launch without Steam fails on `Steam.dll`.
  Starting Steam itself in Offline Mode was not tested; that is the platform's
  licence gate, not the game's network dependency.
* **Steam Cloud was only partly isolated.** It was declined for the first session,
  but a second launch may have re-enabled it. The save files were present, hashed
  and unchanged locally, and a launch alone did not rewrite them, but this run does
  not prove cloud sync was inactive.
* **Two levels, not a campaign.** Levels 1-1 and 1-2 were played; later levels,
  minigames, puzzle and survival modes were not. Audio output was not verified,
  only that the game ran with sound enabled.
* **One machine, one Windows build.** Nothing here says anything about other
  hardware, GPUs or the 3D-accelerated rendering path beyond this machine.
* **The extracted executable has no recorded hash.** The wrapper holds
  `popcapgame1.exe` open while running, so hashing it fails with a sharing
  violation; its size and lifecycle are recorded, its hash is not claimed.

## Reproducing

```powershell
# pre-state: fail-closed audit, install hashes, save snapshot
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-GameOfflineReadiness.ps1 -GameId pvz-goty-steam-3590

# block both executables (elevated, self-removing session)
tools\scratch\pvz-netblock-launch.ps1 `
  -Programs "D:\SteamLibrary\steamapps\common\Plants Vs Zombies\PlantsVsZombies.exe|C:\ProgramData\PopCap Games\PlantsVsZombies\popcapgame1.exe" `
  -SignalDir docs\preservation\data\pvz-offline

# launch, drive, sample, screenshot
start steam://rungameid/3590
powershell -File tools\scratch\pvz-drive.ps1 -Action Shot -Name 07-title
powershell -File tools\scratch\pvz-autoplay.ps1 -Seconds 40

# release: the session deletes its rules
New-Item docs\preservation\data\pvz-offline\block.release
```
