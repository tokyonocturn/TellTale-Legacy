# Legal boundaries

Telltale Legacy exists to keep games that people **already own** working, and to
document how they work. It is written to stay clearly on the preservation side of
that line.

## What this project does

* Reads an installation you own: file inventory, hashes, PE headers, archive
  headers, strings that are already present in the shipped binaries.
* Runs the game through Steam, exactly as Steam would, and records what it observes
  (processes, windows, network endpoints, files it creates).
* Backs up and restores **your** per-user save and preference data on **your**
  machine.
* Documents online dependencies so that their failure can be understood.
* Temporarily and reversibly blocks a publisher API hostname in the local hosts
  file to test offline behaviour, then removes the block.

## What this project does not do

* **No DRM circumvention.** The executable contains a Steam DRM stub (`.bind`).
  This project does not patch, unpack, strip, emulate, or bypass it, and does not
  provide tools that do. A valid Steam licence and the Steam client are required.
* **No authentication or licence bypass.** No Steam emulator, no fake ticket, no
  `steam_appid.txt` tricks, no offline-licence generation.
* **No substitution of Telltale services.** No mock `api.telltalegames.com`, no
  credential replay, no impersonation of the publisher's account system.
* **No game content in the repository.** No executables, DLLs, `.ttarch` archives,
  extracted assets, decrypted `.prop` files, cinematics, audio, scripts, or
  Dialogue databases.
* **No save data or credentials in the repository.** Save snapshots stay local and
  git-ignored. The probe never touches Steam credentials.
* **No redistribution.** Nothing here lets someone play the game without owning it.

## Why the boundary is drawn here

Preservation and piracy both involve old software, and the difference is
authorisation. The practical test used by this project:

> Could a person with no licence use this to play the game? If yes, it does not
> belong in Telltale Legacy.

Everything shipped here fails that test in the safe direction: a person without a
licence gets nothing but documentation and auditing tools.

## Redistribution of findings

* Hashes, build ids, filenames and observed behaviour are facts and are published.
* Short strings quoted from binaries are included only where they are necessary to
  explain behaviour (API hostnames, error messages, header names). They are not
  sufficient to reconstruct content.
* No byte ranges of proprietary data, no decryption keys, no extracted archives.

## Jurisdiction and responsibility

Laws about reverse engineering, interoperability and format shifting differ by
country. Some jurisdictions permit analysis for interoperability and preservation;
others restrict circumvention even for personal use. You are responsible for
complying with the law where you live and with the Steam Subscriber Agreement.

If a rights holder asks for a change to this repository, the correct response is to
comply for the affected material. Documentation of how a game behaves is not a
substitute for a licence, and this project does not claim any.

## Reporting a boundary violation

If you believe something in this repository crosses the line above, open an issue.
Content that distributes game material will be removed.
