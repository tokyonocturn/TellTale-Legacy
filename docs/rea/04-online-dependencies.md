# REA 04 — Online dependencies and offline behaviour

## What was measured

Two controlled launches, both through Steam (`steam://rungameid/207610`):

| Run | Condition | Result |
| --- | --- | --- |
| A | Normal network | Reached main menu; one remote endpoint held by the game process: `18.245.113.61:443` |
| B | `api.telltalegames.com` → `127.0.0.1` (hosts block, Steam untouched) | Reached main menu; **0 remote endpoints**; one `127.0.0.1:443` connect attempt |

Endpoint identification in run A came from the Windows DNS cache, not from guessing
the IP:

```
Entry                     Data           Type
api.telltalegames.com     18.245.113.61  1
```

Reverse lookup: `server-18-245-113-61.dfw57.r.cloudfront.net`. The hostname is also
reachable at `18.245.113.77/.118/.119`, i.e. a CDN front, so blocking a single IP
would not be sufficient — the probe blocks the hostname.

## The single startup-time publisher dependency

During the splash the game opens an HTTPS connection to
**`api.telltalegames.com`**. The executable carries the Telltale account stack:

```
X-TTG-client:  X-TTG-build:  X-TTG-game:  X-TTG-platform:
X-TTG-user:    X-TTG-raw-platform:
Authorization: TTG
TTG_Authorization
User-Agent: XAUTH_TT_PCSTM_UA
Software\Telltale Games\
"Sorry, this account is not authorized to access this game."
```

These are request-signing/account headers for Telltale's own service, separate from
Steam. No other game-owned hostname was observed in the DNS cache or in the game's
TCP table during startup.

**Inference:** the splash performs an account/session check and news fetch. The
connection is not required to continue, because run B reached the identical menu
with the host unreachable. The exact request paths could not be observed without
TLS interception, which was deliberately not performed.

## What degrades offline

| Feature | Offline behaviour | Evidence |
| --- | --- | --- |
| Main menu | Works | run B |
| Play / episode selection UI | Present | run B menu capture |
| Live news banner | Replaced by static text | run B menu capture |
| `EPISODE STATUS` | Shows a red alert badge in **both** runs | run A and run B |
| Steam achievements/stats | Cannot unlock offline | `SteamUserStats` callbacks; `com.telltalegames.*` stat ids |
| Steam Auto-Cloud sync | Local file `steam_autocloud.vdf` written; sync needs Steam online | file created on first run |
| Steam DRM check | Requires a valid cached licence | `.bind` section |

The red badge on `EPISODE STATUS` is **not** an offline-only symptom: it was
present in the fully online run too, on a machine where no episode had ever been
played. It most likely reflects "no episode progress / not signed in to a Telltale
account", not a network failure. It is recorded as unexplained rather than claimed.

## Steam-side dependency

Steam itself is mandatory and is **never** blocked or bypassed by this project.
Two facts shape the offline story:

1. The Steam DRM stub (`.bind`) requires the Steam client and a licence. Legitimate
   offline play means Steam Offline Mode with a cached ticket.
2. Achievements use Steam user stats (`SteamUserStats`,
   `UserStatsReceived_t`). While Steam is offline these cannot be stored; Steam
   queues nothing for a game that never connected, so achievements earned offline
   are simply not awarded.

## Steam Auto-Cloud, not a Telltale cloud

No `SteamRemoteStorage`/`ISteamRemoteStorage` strings were found in the executable.
The only cloud artefact is `steam_autocloud.vdf` in the save folder:

```
"steam_autocloud.vdf"
{
    "accountid"  "<id>"
}
```

This is Steam's Auto-Cloud path marker. Saves are ordinary local files; there is no
second, Telltale-hosted save service to substitute.

## Offline test procedure

```powershell
# 1. Block the publisher hostname (elevated; reversible, marked block in hosts)
.\tools\Invoke-OfflineProbe.ps1 -Action Block

# 2. Launch through Steam and record what the process actually does
.\tools\Start-ObservedSession.ps1 -ViaSteam -Label offline -ObservationSeconds 75

# 3. Restore DNS
.\tools\Invoke-OfflineProbe.ps1 -Action Unblock   # elevated
```

`-Action Status` reports whether the block is active and what each domain currently
resolves to, which is also useful for diagnosing a machine left in the blocked
state.

## Remaining work

* Full machine-offline run with Steam in Offline Mode (needs an attended Steam
  client toggle; not automatable from this project).
* Verify whether `EPISODE STATUS` and the badge behave differently with a Telltale
  account session present.
* Confirm no additional endpoints appear later in gameplay (main menu only so far).
