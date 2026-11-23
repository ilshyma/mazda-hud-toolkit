# Changelog

All notable changes to the Mazda CarPlay & Android Auto HUD Toolkit.

## [v2.6.1] — 2026-11-22

### Added
- **Tweak scan** — USB status check now detects traces of third-party Mazda mods (MZD-AIO, custom JS/Opera mods, foreign LD_PRELOAD lines, non-stock GUI apps) and saves a report + file copies to `hud-mod/logs/` for remote analysis
- **USB Update button** in the XSS panel (re-copy hud-mod files from the stick without a full reinstall)
- `ARCHITECTURE.md` — full technical reference: shim injection, cross-process cooperation, HUD protocol, USB install chain, build system, diagnostics
- `diagnose_remote.sh`, `rollback_verify_remote.sh`, `validate_remote.sh` for SSH-based diagnostics

### Changed
- Updated shims: `libpatch-blmjciaapa.so` and `libpatch-blmjcicarplay.so` (0m distance fix, T-junction icons)
- Menu UI: USB stick option separated from SSH-dependent items (clearer first-time experience)
- `toolkit.bat`: parity fixes with `toolkit.sh`; strip CR from `hud_config` on Windows

### Fixed
- `toolkit.bat` wrote `hud_config` with CRLF — now stripped by `install.sh` on the CMU side

## [v2.6.0] — 2026-11-16

### Added
- **Unified CarPlay + Android Auto HUD** in one package — both phone platforms in a single install
- **User-configurable traffic side** (RHT/LHT) and **speed unit** (KMH/MPH) via `hud_config`
- Cross-process speed-limit relay: stock nav speed stays visible during CarPlay/AA navigation
- Anti-flicker: active-session marker prevents OEM/CarPlay frame interleaving on the HUD
- Full USB install chain: `install.sh`, `uninstall.sh`, `usb_run.sh` with numbered log folders, on-screen result dialogs, and `system.txt` snapshots
- `hud_probe.sh` for runtime diagnostics
- MD5SUMS for shim integrity verification on the stick
- Localized README files (DE, ES, PT, UK)

### Changed
- `UNIFIED` path moved from `files/unified` to `files/hud`
- `toolkit.sh` / `toolkit.bat` prompt for traffic side + speed unit before USB creation and SSH install
- `files/VERSION` now stamped into every on-screen dialog and log

## [v2.5] — 2026-11-06

### Added
- Wireless CarPlay support (WCP mod integration)
- RHD (right-hand drive) roundabout icon fix

### Reverted
- WCP mod removed — caused boot loop on EU unit (reverted in `1213f2a`)

## [v2.4.3] — 2026-10-20

### Fixed
- `toolkit.bat`: `M_INFO` marker `> ` was parsed as a redirect operator by cmd.exe, silently eating every info-level line including the "In the car:" USB instructions; changed to `. `

## [v2.4.2] — 2026-10-20

### Fixed
- `toolkit.bat`: "18 MISSING" false alarm — trailing backslash in PowerShell `-File` argument was parsed as an escaped quote, making every `Test-Path` fail

## [v2.4.1] — 2026-10-20

### Fixed
- `toolkit.bat`: CRLF line endings restored (Git was converting to LF on checkout)
- Git Bash fallback banner added when toolkit.bat is run inside Git Bash

## [v2.4] — 2026-10-19

### Added
- **Toolkit versioning** — `files/VERSION` is the single source of truth; version shown in menu header, on-screen FACTS line, and every log file
- A photo of the error dialog now identifies the exact build

## [v2.3] — 2026-10-19

### Fixed
- **E2 "not a CMU" false negative** on WCP-only units — installer now accepts either `sm.conf` or `sm_WCP.conf`; dies only when both are missing

## [v2.2] — 2026-10-19

### Added
- E2 diagnostic dump: on "not a CMU" error, `install.sh` now logs `/jci` layout, mounts, and `version.ini` to `run.log` for remote diagnosis

## [v2.1] — 2026-10-18

### Added
- **Option B — Bootstrap SSH key**: generates `id_rsa_cmu`, pushes public key to CMU via one-time password, verifies key-based login
- Lazy key check: USB stick creation no longer requires the SSH key
- Windows `toolkit.bat` hardening pass

## [v2.0] — 2026-10-15

### Added
- **USB-only install** — insert stick, tap Install on screen, done (no SSH/Wi-Fi/laptop needed)
- CVE-2024-8359 `.up` filename injection auto-triggers the install dialog (~30s after inserting)
- Stepper UI: 3-step progress for install, 2-step for uninstall, timer for status
- Reboot countdown with "Do not turn off the ignition" warning
- XSS fallback: Media → USB → tap any track → HUD+/HUD-/HUD? buttons
- Windows `.up` payload creation via PowerShell

## [v1.0] — 2026-10-09

### Added
- Initial release: CarPlay turn-by-turn on HUD via SSH install
- `toolkit.sh` (macOS) and `toolkit.bat` (Windows) with menu-driven workflow
- KidMixer shim-based approach (`libpatch-blmjcicarplay.so`)

[v2.6.1]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.6.0...v2.6.1
[v2.6.0]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.5...v2.6.0
[v2.5]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.4.3...v2.5
[v2.4.3]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.4.2...v2.4.3
[v2.4.2]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.4.1...v2.4.2
[v2.4.1]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.4...v2.4.1
[v2.4]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.3...v2.4
[v2.3]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.2...v2.3
[v2.2]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.1...v2.2
[v2.1]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v2.0...v2.1
[v2.0]: https://github.com/ilshyma/mazda-hud-toolkit/compare/v1.0...v2.0
[v1.0]: https://github.com/ilshyma/mazda-hud-toolkit/releases/tag/v1.0
