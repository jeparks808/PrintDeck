# Changelog

Each release's .deb is attached to its [GitHub release](https://github.com/jeparks808/PrintDeck/releases). To install
it on a jailbroken iPad (iOS 5), copy it over, run `dpkg -i` as root, then run `su mobile -c uicache`.

## 0.2.1 (23 Nov 2026)
- **Bed mesh drawn to scale on the real plate.** The view shows the Centauri Carbon's plate outline and its 256 mm
  printable square, and places the probed area where the printer probed it. There is one grid line and one dot per
  probe point, and a dashed line marks the probed footprint. The panel lists the probe count, spacing and X/Y range.
- The mesh view opens from the front-left, as you stand at the printer. Overlapping parts of the surface are drawn
  far-first, and the demo mesh spans 20–246 mm like a real one.
- [docs/FEATURES.md](docs/FEATURES.md): what PrintDeck adds over the printer's web page and ElegooSlicer, with
  screenshots.

## 0.2.0 (23 Nov 2026)
- **Slice** STL files on the iPad (CuraEngine 15.04 with gyroid infill), using ElegooSlicer's stock Centauri Carbon
  profiles and your own presets.
  - **Four CANVAS filament slots**, with **From CANVAS** to copy the loaded spools and a **Flushing volumes** editor
    that uses ElegooSlicer's colour rule.
  - **Print options**: plate type, time-lapse and auto bed levelling.
  - The printer's screen shows thumbnails of G-code sliced on the iPad.
- **Design**: a Tinkercad-style modeller with parametric bolts, nuts, threaded holes and gears; Move, Rotate and
  Scale tools; hole cutting by grouping, which runs in the background with a progress bar; and **handy models**.
- **Bed mesh** in 3D with corner-screw tramming hints. `tools/install-meshbridge.sh` installs the helper on the
  printer and starts it at every boot.
- **CANVAS** card and page, **COSMOS** (Klipper + Moonraker) support, **Clear local cache**, and a clearer 3D
  preview while the printer is busy.

## 0.1.0 (19 Nov 2026)
- The first build: a live panel for the Centauri Carbon over SDCP. It shows the camera, the job's progress,
  temperatures with graphs, and fans. It controls pause/resume/stop, temperatures, fans, print speed and the light,
  and it can start prints from the printer's files. A full-screen alert with a sound appears when a print finishes,
  fails or pauses.
