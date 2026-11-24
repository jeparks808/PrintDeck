# PrintDeck

> **Work in progress.** PrintDeck is used every day with a real Centauri Carbon, but it is an ongoing project. Don't
> treat a feature as working unless its README says it was checked on the real printer. Use it at your own risk, and
> keep an eye on prints started from it.

A live panel for the **Elegoo Centauri Carbon** 3D printer: camera, job progress, temperatures, fans, print control
and files. It works with stock or OpenCentauri firmware and with OpenCentauri **COSMOS** (Klipper + Moonraker).

There are two apps:

| | For | Status |
|---|---|---|
| [**`legacy/`**](legacy/README.md) | iPad 1, iOS 5.1.1 (jailbroken), built with Theos | Full featured: the live panel, an on-iPad slicer, a 3D Design page and the bed mesh. SDCP and COSMOS. |
| [**`modern/`**](modern/README.md) | current iPhones and iPads, iOS 17+, SwiftUI, built on Linux with xtool | Stage 1: monitor and control over Moonraker (COSMOS). |

Shared by both:

- [`docs/`](docs/): [COSMOS](docs/COSMOS.md) (what changes on Klipper firmware, backups and rollback) and
  [FEATURES](docs/FEATURES.md) (what PrintDeck adds over the printer's web page and ElegooSlicer, with screenshots).
- [`sim/`](sim/): virtual printers for testing without the real one. `printdeck_sim.py` speaks SDCP,
  `cosmos_sim.py` is Klipper + Moonraker, and `cosmos_check.py` walks PrintDeck's features against either the
  simulator or a real COSMOS printer.
- [`tools/`](tools/): printer-side helpers: `backup-printer.sh` (a full backup before a firmware change) and
  `screen-mirror/` (shows the printer's touchscreen in PrintDeck).

Downloads of the iPad 1 app are on the [Releases](https://github.com/jeparks808/PrintDeck/releases) page; see
[legacy/CHANGELOG.md](legacy/CHANGELOG.md) for what changed.

## Logging in to the printer over SSH
OpenCentauri firmware runs an SSH server. Its default login is user **`root`**, password **`OpenCentauri`**
(case sensitive). Change it with `passwd` once you're in. OpenCentauri also leaves an unauthenticated root shell on
TCP 4567, so anyone on the Wi-Fi can take over the printer until you change the password and turn that shell off.

## License
PrintDeck is free software under the **GNU Affero General Public License v3.0**; see [LICENSE](LICENSE). That covers
both apps, `sim/`, `tools/` and `legacy/meshbridge/`. CuraEngine (`legacy/engine/CuraEngine`) is also AGPL-3.0,
from Ultimaker. The bundled handy models and slicer profiles keep their own authors' terms (see
[legacy/README.md](legacy/README.md#credits)).

## Contributors
- [jeparks808](https://github.com/jeparks808): creator and maintainer. Owns the project, its design and direction,
  and tests everything on the real printer and iPad.
- [Claude](https://github.com/claude) (Anthropic's AI, through Claude Code): co-wrote the code, the reverse
  engineering and the docs. It is credited on every commit as a co-author.
