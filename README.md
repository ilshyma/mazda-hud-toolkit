# Mazda CarPlay & Android Auto HUD Toolkit

Turn-by-turn navigation on the windshield HUD for **CarPlay** and **Android Auto** on Mazda CMU150 (firmware `74.00.324`).

**Site:** [mazda-toolkit.monodev.org](https://mazda-toolkit.monodev.org)

**Downloads:** [Latest release](../../releases/latest)

**Applies to:** CX-5 KF, CX-8, CX-9 (2018+) and same-platform units with FW 74.00.324.

## What it does

| Without mod | With mod |
|-------------|----------|
| HUD shows speed only during CarPlay/AA nav | HUD shows turn arrows, distance, street name |
| Speed limit disappears when phone nav active | Speed limit from stock maps stays visible |
| — | Roundabout icons, lane guidance (stock nav) |

## How it works

Four `.so` shims injected via `LD_PRELOAD` into the stock OEM services — no binaries modified, clean uninstall:

| Shim | Target process | Purpose |
|------|---------------|---------|
| `libpatch-blmjcicarplay.so` | jciCARPLAY | CarPlay nav → HUD bridge |
| `libpatch-blmjciaapa.so` | jciAAPA | Android Auto nav → HUD bridge |
| `libpatch-svcjcinavi.so` | svcjcinavi | Stock nav arbiter, speed limit relay |
| `libpatch-aap_service.so` | aap_service | AA protocol 1.6 helper |

## v2.6.0 changes

- Unified CarPlay + Android Auto HUD support in one package
- User-configurable traffic side (RHT/LHT) and speed unit (KMH/MPH)
- Cross-process cooperation: speed limit from stock nav visible during CarPlay navigation
- Anti-flicker: active session marker prevents OEM/CarPlay frame interleaving
- USB install with version display on the popup
- Detailed diagnostics: logs written to USB after every install/uninstall/status run

## Installation

Two methods:

1. **USB stick** (no laptop connection needed) — the toolkit creates a bootable USB that shows an Install dialog on the car's screen
2. **SSH** (laptop connected via USB) — direct install over the network

Run `toolkit.sh` (macOS/Linux) or `toolkit.bat` (Windows) and follow the menu.

## Architecture

Full technical reference: **[ARCHITECTURE.md](ARCHITECTURE.md)** — shim injection, cross-process cooperation, HUD protocol, USB install chain, build system, diagnostics, and gotchas.

## Based on

- [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) (AGPL-3.0)
- [VitaliyKurokhtin/oem-aa-mod](https://github.com/VitaliyKurokhtin/oem-aa-mod) — Android Auto HUD support

## License

AGPL-3.0 (inherited from upstream KidMixer/mazda-carplay-hud).
