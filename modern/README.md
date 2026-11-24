# PrintDeck for current iPhones and iPads

> **Work in progress: stage 1 (monitor and control).** A new SwiftUI app for iOS / iPadOS 17 and later. It's built on
> **Linux** with [xtool](https://github.com/xtool-org/xtool); no Mac is needed. The iPad 1 app in the repository root is
> separate and unchanged.

It talks to Klipper printers through **Moonraker**, such as the Centauri Carbon running OpenCentauri **COSMOS**.
Support for Elegoo's SDCP protocol (stock and OpenCentauri patched firmware) is planned.

## What works so far
- **Connect** by typing the printer's address. Automatic discovery needs Apple's multicast entitlement, so it comes later.
- **Dashboard:** the live camera (MJPEG), the current job with progress, layer, elapsed time, time left and finish
  time, Pause / Resume / Cancel (Cancel asks first), and nozzle / bed / chamber temperatures with a 10-minute graph.
  Tap the nozzle or bed to set a target. There are also the part, aux and case fans, the case light, and print speed
  presets.
- **Files:** the printer's G-code, with the slicer details and thumbnail, and **Print this file** (it asks first).

## Layout
- `Sources/PrintDeckCore`: printer communication and models (`MoonrakerClient`, `PrinterSnapshot`, MJPEG splitter).
  It has no UI, and it builds and is tested on Linux.
- `Sources/PrintDeck`: the SwiftUI app (iOS only; wrapped in `#if os(iOS)` so the package builds on Linux).
- `Sources/pdcli`: a read-only command-line check against a real printer.
- `Tests/PrintDeckCoreTests`: tests using replies saved from a real Centauri Carbon running COSMOS.

## Building on Linux
One-time setup: install Swift 6.4 (for example with [swiftly](https://www.swift.org/install/linux/)) and
[xtool](https://xtool.sh/documentation/xtooldocs/installation-linux), then run `xtool setup` (sign in to Apple and point
it at `Xcode.xip`).

```bash
cd modern
swift test                                    # core tests, on Linux
swift run pdcli 192.168.0.185                 # read the printer's status
xtool dev                                     # build, sign and install on the connected iPhone / iPad
```

The first install on a device needs **Developer Mode** turned on (Settings → Privacy & Security). With a free Apple
account, the app has to be reinstalled every 7 days.
