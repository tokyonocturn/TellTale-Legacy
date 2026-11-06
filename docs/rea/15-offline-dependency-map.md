# REA 15 — Offline dependency map (Phase 1)

What the installed game actually needs from the network, established from the shipped
files and from a live session that was observed without being touched. Every claim below
names its evidence.

## Method

| Source | What it can show |
|---|---|
| `strings` over `WalkingDead101.exe`, `steam_api.dll`, `fmodex.dll` | literals the code can use: hostnames, URLs, OpenSSL/curl boilerplate |
| `Get-NetTCPConnection -OwningProcess <game>` sampled over time | what the running game actually connects to |
| `Resolve-DnsName` for the publisher hosts | which address belongs to which name |
| `appmanifest_207610.acf` | which depots/ DLC are actually installed |
| `Pack/<dir>` inventory | which episodes have their archives locally |
| `ipconfig /displaydns` | corroboration of recently resolved names |

The live session belonged to the project owner and was never given focus, input, paused or
closed. Connection sampling is read-only.

## Endpoints found

**In the binary** (literals):

| Literal | Meaning |
|---|---|
| `https://meta.telltalegames.com/1/` | the only publisher URL compiled into the executable; a versioned metadata/config service |
| `www.telltalegames.com` | appears once, alongside certificate/README boilerplate from bundled OpenSSL |
| `www.verisign.com`, `ocsp/crl.verisign.com`, `www.openssl.org`, `www.lua.org` | library boilerplate baked into the embedded TLS/zlib/Lua builds — **not** endpoints this game calls |

There is **no** `api.telltalegames.com` literal in the executable, so that host is either
composed at runtime or supplied by the metadata service. It is nonetheless the host the
running game talks to.

**At runtime**, sampled every 10 s for two minutes during real play:

| Remote address | Held | Attribution |
|---|---|---|
| `18.245.113.119:443` | **12 / 12 samples**, state `Established` | `api.telltalegames.com` → `18.245.113.61/.77/.118/.119` (CloudFront, `server-18-245-113-119.dfw57.r.cloudfront.net`) |
| — | never seen | `meta.telltalegames.com` → `108.156.245.57/.85/.96/.120`, a different CloudFront distribution |
| — | never seen | `www.telltalegames.com` → `184.32.29.238` and others |

So during play the game keeps a **persistent TLS connection to the API host**, and the one
URL compiled into it is not the one it uses. Whether the connection carries anything the
game needs is a separate question, and the answer has to come from running without it.

## Classification

| Dependency | Role | Verdict |
|---|---|---|
| `api.telltalegames.com` | long-lived socket during play; presumably stats/season state | **unknown-but-suspicious** — the offline launch must decide it |
| `meta.telltalegames.com` | compiled-in metadata URL; not contacted during the observed window | **optional or startup-only** — needs a cold-launch test |
| `www.telltalegames.com` | one literal next to cert boilerplate | **obsolete** — no observed use |
| Steam (`steam_api.dll`) | DRM/ownership gate and overlay | **essential and legitimate** — must keep working; the project never bypasses it |
| Local archives | episodes and their assets | **essential, already local** |

## Local content coverage

`appmanifest_207610.acf` reports `StateFlags 4` (fully installed), `buildid 244978`, one
depot (`207611`, 3,809,843,441 bytes) and **no DLC depots**.

| Pack directory | Files | Size | Content |
|---|---|---|---|
| `Pack/default` | 27 archives | 509 MB | **Episode 1** (`WalkingDead101` archives: txmesh, ms, voice, anichore) |
| `Pack/WalkingDead102` | 25 archives | 980 MB | **Episode 2** |
| `Pack/WalkingDead103` | 21 archives | 685 MB | **Episode 3** |
| `Pack/WalkingDead104` | 22 archives | 706 MB | **Episode 4** |
| `Pack/WalkingDead105` | 18 archives | 741 MB | **Episode 5** |

Each episode directory carries its own `voice` archive, so dialogue audio is local for all
five.

**400 Days is not installed.** The only trace of it is the `0_20_WalkingDead106_*_backpatch`
archives inside each episode's pack, and there is no `Pack/WalkingDead106` directory and no
DLC depot in the manifest. It therefore cannot be tested on this machine and is recorded as
**not available**, not as passing.

## Episode 1 Chapter 2 and the network

The earlier record in `12-gameplay-automation.md` left open whether the stalled chapter was
an online dependency. It was not:

- The stall reproduced while `api.telltalegames.com` was **reachable and connected** — the
  established socket above was present during it.
- The cause was the input driver's two defects (26 px window/client offset; presses sent
  without a preceding mouse-move event), fixed in `46efac2`.
- With the driver fixed the owner played past that chapter: the save directory went from six
  slots at the pre-session backup to nine during the recorded session, with `prefs.prop`
  growing 7,770 → 11,010 bytes.

A network cause is therefore excluded for that symptom by evidence, not by assumption.

## What is still unknown

- Whether the API socket is **required** or merely pessimistic. Only a cold launch with the
  host unavailable can answer it, and that requires the game to be closed.
- Whether the metadata service is contacted at startup (our window started after the
  frontend had already loaded).
- Whether the episode transition performs an entitlement check against the API.
