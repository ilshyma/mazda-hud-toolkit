# Mazda CMU150 HUD Toolkit — Architecture Reference

> **Version:** 2.6.0 · **Target firmware:** 74.00.324 (NA/EU)
> **Platform:** Mazda Connect CMU150 — ARM Cortex-A9, Linux 3.0.35, 512 MB RAM

This document describes the full architecture of the HUD toolkit: how the
shims get injected, how they cooperate, what the installer does, and how
the toolkit builds and deploys everything.

---

## Table of contents

1. [What it does](#1-what-it-does)
2. [System context](#2-system-context)
3. [LD_PRELOAD shim architecture](#3-ld_preload-shim-architecture)
4. [The four shims](#4-the-four-shims)
5. [Cross-process cooperation (hud_share.h)](#5-cross-process-cooperation-hud_shareh)
6. [User configuration (hud_config)](#6-user-configuration-hud_config)
7. [HUD output protocol](#7-hud-output-protocol)
8. [USB unlock and install chain](#8-usb-unlock-and-install-chain)
9. [On-device installer (install.sh)](#9-on-device-installer-installsh)
10. [Build system](#10-build-system)
11. [File layout](#11-file-layout)
12. [Source code map](#12-source-code-map)
13. [Gotchas and hard-won lessons](#13-gotchas-and-hard-won-lessons)

---

## 1. What it does

The toolkit adds **turn-by-turn navigation on the windshield HUD** for
CarPlay and Android Auto on Mazda vehicles equipped with CMU150 (2014–2021
Mazda 3/6/CX-5/CX-9/MX-5). Stock Mazda Connect only shows HUD guidance
from its built-in NNG navigation — phone projection gets nothing.

The mod intercepts navigation D-Bus messages inside the existing OEM
processes and writes them to the HUD via the stock `com.jci.vbs.navi`
interface. No new daemons, no modified binaries — just four `.so` shims
loaded via `LD_PRELOAD`.

**What the driver sees:**

| Without mod | With mod |
|-------------|----------|
| HUD shows speed only during CarPlay/AA nav | HUD shows turn arrows, distance, street name |
| Speed limit disappears when phone nav active | Speed limit from stock maps stays visible |
| — | Roundabout icons, lane guidance (stock nav) |

---

## 2. System context

### Hardware

- **SoC:** Freescale i.MX6 (ARM Cortex-A9 single-core, 1 GHz)
- **RAM:** 512 MB DDR3
- **Storage:** 2 GB eMMC (rootfs) + 8 MB SPI NOR flash (bootloader/config)
- **Display:** LCD center stack + optional windshield HUD (combiner projection)
- **Connectivity:** USB host (phone projection), Bluetooth, Wi-Fi (some units)

### Software stack

- **Kernel:** Linux 3.0.35-g42f41ec (custom Freescale BSP)
- **Init:** custom `sm_svclauncher` service manager (not systemd)
- **Services:** JCI/Mazda proprietary — `jciCARPLAY`, `jciAAPA`, `svcjcinavi`, `aap_service`
- **IPC:** D-Bus (session bus, `com.jci.*` namespace)
- **HUD interface:** `com.jci.vbs.navi.SetHUDDisplayMsgReq` — a D-Bus method on `svcnavi`
- **Filesystem:** rootfs is read-only by default; `/data_persist/` is writable, survives reflash

### Key paths on the CMU

| Path | Purpose |
|------|---------|
| `/jci/sm/sm.conf` | Service manager config (non-WCP units) |
| `/jci/sm/sm_WCP.conf` | Service manager config (WCP-only units) |
| `/jci/carplay/blmjcicarplay.so` | Stock CarPlay BLM library |
| `/jci/navi/svcjcinavi.so` | Stock navigation service |
| `/data_persist/oem-aa-mod/` | Mod install directory (shims + config) |
| `/data_persist/hud-mod-backup/` | Pristine backups of modified files |
| `/data_persist/hud_config` | User preferences (traffic side, speed unit) |
| `/etc/devmgr_config_master.xml` | Master device manager config (NaviSupported flag) |

---

## 3. LD_PRELOAD shim architecture

The core technique: the service manager (`sm_svclauncher`) launches each OEM
service by `dlopen()`-ing its `.so`. By adding an `LD_PRELOAD` environment
variable to the service's config in `sm.conf`, Linux loads our shim `.so`
**before** the OEM code runs.

### How it works

1. **sm.conf patching** — the installer adds `<environ_var>` lines:
   ```xml
   <service ... name="jciCARPLAY" ...>
       <environ_var env_name="LD_PRELOAD"
                    env_value="/data_persist/oem-aa-mod/libpatch-blmjcicarplay.so"/>
   ```

2. **Constructor runs first** — each shim has an `__attribute__((constructor))`
   function that fires at load time, before the OEM code's `main()`.

3. **Process gating** — each shim reads `/proc/self/cmdline` to verify it's in
   the right process. If not (e.g. a watchdog child that inherits `LD_PRELOAD`),
   it stays completely inert — zero overhead, zero side effects.

4. **PLT interposition** — the shim replaces select functions from `libdevmgr_interface.so`
   (the CarPlay shim) or intercepts D-Bus calls (the AA/navi shims) to capture
   navigation events.

5. **HUD output** — captured events are translated to `SetHUDDisplayMsgReq`
   D-Bus calls, which the stock HUD display firmware renders.

### Why LD_PRELOAD and not binary patching

- **Survives firmware updates** — the OEM binaries are untouched; a reflash just
  removes the `LD_PRELOAD` lines from sm.conf
- **Clean uninstall** — restore the backup sm.conf, delete the mod directory
- **No signature breakage** — OEM code integrity checks pass because nothing changed
- **Multiple shims coexist** — each in its own process, no conflicts

---

## 4. The four shims

### `libpatch-blmjcicarplay.so` (CarPlay HUD bridge)

**Target process:** `jciCARPLAY` (via `sm_svclauncher -l jciCARPLAY`)

**What it does:**
- Intercepts `IdentifyData` messages from the CarPlay stack (`devmgr_interface`)
  that carry navigation maneuver bytes at offset `0x5204`
- Parses Apple-format maneuver type, junction angle, drive side, distance, street name
- Classifies into Mazda HUD icon codes (straight, turn-left, roundabout, etc.)
- Handles Vietnamese UTF-8 normalization (3-byte → 2-byte for the HUD font)
- Writes to HUD via `com.jci.vbs.navi.SetHUDDisplayMsgReq`
- Reads speed limit from stock nav via `hud_share::read_oem_speed()` (cooperative mode)
- Publishes `hud_carplay_active` marker so the navi shim knows to yield

**Key source files:**
- `main.cpp` — constructor, process gate, hud_config load
- `nav.cpp` — maneuver classification, distance unit conversion
- `hud/hud_send.cpp` — HUD D-Bus output, 2 Hz tick loop, seqlock producer
- `devmgr_shim.cpp` — PLT interposition of `IdentifyData`

### `libpatch-blmjciaapa.so` (Android Auto HUD bridge)

**Target process:** `jciAAPA` (via `sm_svclauncher -l jciAAPA`)

**What it does:**
- Intercepts the AA navigation D-Bus interface via `svcnavi` transport
- Parses Google-format turn events, distance, street names
- Converts AA navigation icons to Mazda HUD icon codes
- Reads hud_config for traffic side (LHT/RHT) and roundabout icon selection
- Maps AA distance units to Mazda HUD unit enum

**Note:** Unlike CarPlay, AA navigation goes *through* `svcjcinavi` (the stock nav
service), so the merge shim can splice the speed limit directly — no tmpfs
side channel needed.

### `libpatch-svcjcinavi.so` (stock nav merge shim / HUD arbiter)

**Target process:** `svcjcinavi` (via `sm_svclauncher -l jcinavi`)

**What it does:**
- Intercepts the OEM NNG navigation's HUD frames
- Publishes the speed limit to `/tmp/hud_oem_speed` for the CarPlay shim
- Monitors `/tmp/hud_carplay_active` — while fresh, drops OEM frames to prevent
  flickering between CarPlay and stock nav HUD output
- Optionally reads street name from a fixed offset in the stock `svcjcinavi.so`
  binary (only on known-good 74.00.324A builds, verified by MD5)
- Acts as the arbiter: OEM nav gets the HUD when no phone projection is active

### `libpatch-aap_service.so` (AA protocol 1.6 helper)

**Target process:** `aap_service`

**What it does:**
- Handles Android Auto protocol version 1.6 specifics
- Works in conjunction with `blmjciaapa` for newer AA protocol features
- Minimal shim — mostly pass-through with selective interception

---

## 5. Cross-process cooperation (hud_share.h)

The hardest problem: **CarPlay and stock navigation run in different processes**
and both want to write to the HUD. Without coordination, their frames interleave
and the HUD flickers (this was bug #3 in v2.6.0-beta when the mechanism was
accidentally stripped).

### The mechanism

Two files on tmpfs (`/tmp/`, cleared at boot) carry the coordination:

#### `/tmp/hud_oem_speed` — speed limit relay

- **Writer:** `libpatch-svcjcinavi.so` (the navi merge shim)
- **Reader:** `libpatch-blmjcicarplay.so` (the CarPlay shim)
- **Format:** `"<limit> <unit>\n"` (e.g. `"50 1\n"` = 50 km/h)
- **Purpose:** The stock NNG navigation knows the speed limit from its map database.
  When CarPlay navigation is active, the CarPlay shim reads this file to paint
  the speed limit on the HUD alongside CarPlay's turn arrows.
- **Existence signal:** If this file exists, the CarPlay shim knows the merge shim
  is running (cooperative mode). If absent, it falls back to legacy `splim` file.

#### `/tmp/hud_carplay_active` — session lifecycle marker

- **Writer:** `libpatch-blmjcicarplay.so` (refreshed ~1 Hz while CarPlay nav active)
- **Reader:** `libpatch-svcjcinavi.so` (the merge shim)
- **Format:** `"<unix_timestamp>\n"`
- **TTL:** 3 seconds (`kCarplayActiveTtlSec`)
- **Purpose:** While this file is fresh (timestamp within 3 seconds of now),
  the merge shim **drops** OEM HUD frames. This prevents the stock nav from
  writing blank maneuvers that flicker against CarPlay's real guidance.
- **Crash recovery:** If the CarPlay process crashes, it stops refreshing. After
  3 seconds the timestamp goes stale, and OEM frames resume automatically.
- **Clock safety:** The CMU often boots with RTC at 1970 until a GPS fix arrives.
  A future timestamp (from a clock step) is treated as stale, not as permanently
  blocking OEM frames.

### Atomic writes

Both files are written via `write_file_atomic()`:

```
write to /tmp/hud_oem_speed.<pid>  (temp file)
rename() temp → /tmp/hud_oem_speed (atomic on POSIX)
```

This ensures:
- A reader never sees a half-written value (torn read)
- A pre-planted symlink at the final path is replaced, not followed
- If the writer crashes mid-write, only the temp file is left (cleaned on next write)

### Why tmpfs

- **No flash wear** — `/tmp` is a RAM filesystem
- **Cleared at boot** — no stale state from a previous session
- **Fast** — no disk I/O, important for the 2 Hz tick rate

---

## 6. User configuration (hud_config)

**File:** `/data_persist/hud_config` (on the CMU)

**Format:**
```
traffic_side=RHT
speed_unit=KMH
```

**Options:**

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `traffic_side` | `RHT` / `LHT` | `RHT` | Roundabout icon direction (clockwise vs counter-clockwise) |
| `speed_unit` | `KMH` / `MPH` | `KMH` | Distance display: meters/km vs feet/miles |

**How it's set:**
1. The toolkit (`toolkit.sh`) prompts the user before creating a USB stick or SSH-installing
2. The answer is written to `hud-mod/hud_config` on the USB stick
3. `install.sh` copies it to `/data_persist/hud_config`
4. Each shim reads it once at load time via `hud_config::load()`

**Implementation:** `patches/common/hud_config.h` — header-only, same pattern as
`hud_share.h`. Singleton struct with lazy loading; tolerates missing file (defaults
to RHT + KMH).

**Separate from `libpatch.conf`:** `libpatch.conf` is for developer/advanced tuning
(14 options like `hud_transport`, `force_street_name`, etc.). `hud_config` is for
end-user preferences that the toolkit UI sets.

---

## 7. HUD output protocol

The windshield HUD is controlled via a single D-Bus method:

```
Service:   com.jci.vbs.navi
Object:    /com/jci/vbs/navi
Interface: com.jci.vbs.navi
Method:    SetHUDDisplayMsgReq
```

### Message fields

| Field | Type | Description |
|-------|------|-------------|
| `displayTurnIcon` | uint16 | Turn icon code (0–51 in the icon bank) |
| `displayTurnNumber` | uint16 | Distance value × 1000 (for fractional display) |
| `displayTurnUnit` | uint8 | Unit: 1=m, 3=km, 5=mi, 6=ft |
| `displayTurnStreet` | string | Street name (UTF-8, max ~20 chars on HUD) |
| `displaySpeedLimit` | uint16 | Speed limit value |
| `displaySpeedUnit` | uint8 | Speed unit code |
| `displayGuidancePoint` | bool | Whether guidance is active |

### Icon banks

The HUD has 51+ icon slots. Key ranges:

| Range | Purpose |
|-------|---------|
| 0 | No icon / clear |
| 1–12 | Basic turns (straight, left, right, U-turn, etc.) |
| 13–24 | Highway maneuvers (merge, exit, fork) |
| 25–36 | Destination/waypoint icons |
| 37–48 | Roundabout icons — RHT (clockwise) |
| 49–60 | Roundabout icons — LHT (counter-clockwise) |

The `roundabout_icon()` function in `hud_send.cpp` selects the correct bank based
on `hud_config::is_lht()`.

### 2 Hz tick loop

`hud_send.cpp` runs a sender thread at ~2 Hz (500ms interval). Each tick:
1. Reads the current navigation state from a seqlock-protected buffer
2. Reads speed limit (from `hud_share::read_oem_speed()` or legacy splim)
3. Sends `SetHUDDisplayMsgReq` to the HUD
4. Refreshes `hud_carplay_active` marker if CarPlay nav is active

The seqlock pattern prevents torn reads between the PLT interposition thread
(which captures nav events at arbitrary times) and the sender thread.

---

## 8. USB unlock and install chain

The CMU has no SSH by default. The USB unlock exploits CVE-2024-8359
(ZDI-24-1191) — the firmware reflash scanner passes `.up` filenames to `system()`
unsanitized, allowing command injection.

### Chain of execution

```
USB inserted
  → jci-autoupdate scans for .up files
    → crafted .up filenames encode: sh /mnt/sd[abcd]1/t
      → trampoline 't' deduplicates and calls tweaks.sh
        → tweaks.sh shows jci-dialog popup (Install / Uninstall / Status)
          → user picks Install
            → usb_run.sh install
              → copies hud-mod/ to /tmp/hud-mod on CMU
                → runs install.sh on the CMU
                  → installs shims, patches sm.conf, sets NaviSupported
                    → reboot → shims load via LD_PRELOAD
```

### Key files on the USB stick

```
MZD/                            (root of FAT32 USB partition)
├── jci-autoupdate              (triggers the reflash scanner)
├── *.up                        (CVE-2024-8359 injection payloads)
├── t                           (trampoline — deduplicates parallel calls)
├── tweaks.sh                   (dialog launcher, shows version popup)
└── hud-mod/
    ├── VERSION                 (stamped into popup title)
    ├── hud_config              (traffic_side + speed_unit)
    ├── install.sh              (the actual installer)
    ├── uninstall.sh            (clean removal)
    ├── usb_run.sh              (orchestrator: logging, dialogs, error codes)
    ├── libpatch-blmjcicarplay.so
    ├── libpatch-blmjciaapa.so
    ├── libpatch-svcjcinavi.so
    ├── libpatch-aap_service.so
    ├── libpatch.conf
    ├── aap_system_attributes.xml
    └── aap_system_attributes_UCP.xml
```

### The toolkit creates this structure

`toolkit.sh` (macOS/Linux) and `toolkit.bat` (Windows) handle:
1. Prompting for traffic side + speed unit (`prompt_hud_config()`)
2. Detecting external USB drives (number picker, no typing paths)
3. Formatting as FAT32 with label `MZD`
4. Copying the payload files
5. Writing `hud_config` with the user's choices

---

## 9. On-device installer (install.sh)

Runs on the CMU as root. Idempotent — safe to re-run after updates.

### Steps

1. **Preflight** — verifies sm.conf exists, all shim .so files present, checks
   firmware version (warns if not 74.00.324), verifies svcjcinavi.so MD5
2. **Copy shims** — `libpatch-*.so` + `libpatch.conf` → `/data_persist/oem-aa-mod/`
3. **Patch sm.conf** — strips old LD_PRELOAD lines, inserts fresh ones for all 4 services;
   also patches `sm_WCP.conf` if present. `reset_board="no"` for jciCARPLAY
4. **NaviSupported** — sets `<value>TRUE</value>` in `devmgr_config_master.xml`
   (enables CarPlay nav advertisement)
5. **AA system attributes** — installs XML files for AA navigation subscribe
   (only if the referenced certificates exist on the unit)
6. **Retire splim_bridge** — stops and removes the old external speed-limit
   daemon (now built into the svcjcinavi shim)
7. **hud_config** — copies `hud_config` to `/data_persist/hud_config`

### Safety measures

- Every modified file backed up once to `/data_persist/hud-mod-backup/*.orig`
- Mounts rootfs read-write only during install, re-mounts read-only after
- Sanity checks: counts non-mod lines in sm.conf before and after to catch corruption
- If svcjcinavi.so MD5 doesn't match the known build, disables `force_street_name`
  (which reads at a fixed binary offset) to prevent crashes

---

## 10. Build system

### Toolchain

**M3 cross-compiler** — ARM GCC 4.9.1, targeted at `arm-cortexa9_neon-linux-gnueabi`.
These are Linux x86-64 ELF binaries — on macOS, they run inside Docker.

```bash
# Build the CarPlay shim (from mazda-hud-unified/mazda/)
docker run --rm -v "$(pwd):/src" -w /src ubuntu:22.04 \
  bash -c "make blmjcicarplay"
```

### Makefile targets

| Target | Output | Target process |
|--------|--------|---------------|
| `blmjcicarplay` | `libpatch-blmjcicarplay.so` | jciCARPLAY |
| `blmjciaapa` | `libpatch-blmjciaapa.so` | jciAAPA |
| `svcjcinavi` | `libpatch-svcjcinavi.so` | svcjcinavi |
| `aap_service` | `libpatch-aap_service.so` | aap_service |

### Compiler flags

```
-std=c++11 -D_GLIBCXX_USE_CXX11_ABI=0
--sysroot=$(M3_SYSROOT)
-shared -fPIC -Os -fno-exceptions
```

CarPlay-specific:
```
-DCARPLAY_NO_UDPD_LAUNCH -DCARPLAY_VN_NORMALIZE=1
```

**Critical linker flags:**
```
-lpthread -ldl -lrt
```

The `-lrt` is essential — it provides POSIX timers for the 2 Hz tick loop.
Omitting it causes undefined symbol errors at runtime.

### Source repo

The build source is in `mazda-hud-unified` (the unified CarPlay + AA repo).
There is also an older `mazda-carplay-hud` repo (CarPlay-only, 6 commits ending
at 67ba1f5) — do not build from that one.

---

## 11. File layout

### Toolkit repository (`mazda-hud-toolkit`)

```
mazda-hud-toolkit/
├── toolkit.sh              macOS/Linux toolkit (menu-driven)
├── toolkit.bat             Windows toolkit
├── toolkit.command          macOS double-click launcher
├── .gitignore              excludes id_rsa_cmu, .hud_config
├── README.md               main documentation
├── ARCHITECTURE.md          this file
├── files/
│   ├── VERSION             toolkit version (2.6.0)
│   ├── hud/                the mod package (shipped to CMU)
│   │   ├── VERSION
│   │   ├── MD5SUMS         integrity hashes for the 4 .so files
│   │   ├── install.sh
│   │   ├── uninstall.sh
│   │   ├── usb_run.sh       USB orchestrator
│   │   ├── hud_probe.sh     diagnostic probe
│   │   ├── validate_remote.sh
│   │   ├── diagnose_remote.sh
│   │   ├── rollback_verify_remote.sh
│   │   ├── libpatch-blmjcicarplay.so   (30895 bytes)
│   │   ├── libpatch-blmjciaapa.so      (105667 bytes)
│   │   ├── libpatch-svcjcinavi.so      (15187 bytes)
│   │   ├── libpatch-aap_service.so     (19883 bytes)
│   │   ├── libpatch.conf    developer config (14 options)
│   │   ├── aap_system_attributes.xml
│   │   └── aap_system_attributes_UCP.xml
│   └── usb_unlock/
│       ├── tweaks.sh        dialog launcher (CVE-2024-8359 entry)
│       ├── dev.html         XSS panel fallback
│       └── (other .up payload files)
```

### Source repository (`mazda-hud-unified/mazda/`)

```
mazda/
├── Makefile                 M3 toolchain build
├── patches/
│   ├── common/
│   │   ├── hud_share.h      cross-process cooperation
│   │   ├── hud_config.h     user preferences reader
│   │   └── config.h         developer config (libpatch.conf)
│   ├── blmjcicarplay/
│   │   ├── main.cpp         constructor, process gate
│   │   ├── nav.cpp          maneuver classification
│   │   ├── devmgr_shim.cpp  PLT interposition
│   │   ├── patch.h          master header
│   │   └── hud/
│   │       └── hud_send.cpp  HUD D-Bus output + tick loop
│   ├── blmjciaapa/
│   │   ├── hud/
│   │   │   ├── hud.cpp      AA HUD logic
│   │   │   └── hud_nav.h    turn icon mapping
│   │   └── ...
│   ├── svcjcinavi/
│   │   └── ...              merge shim, speed relay, arbiter
│   └── aap_service/
│       └── ...              AA protocol 1.6 helper
```

---

## 12. Source code map

### Shared headers (patches/common/)

| File | Purpose | Used by |
|------|---------|---------|
| `hud_share.h` | tmpfs-based cross-process hand-off (speed relay + active marker) | blmjcicarplay, svcjcinavi |
| `hud_config.h` | Reads `/data_persist/hud_config` (traffic_side, speed_unit) | blmjcicarplay, blmjciaapa |
| `config.h` | Reads `libpatch.conf` developer settings (14 options) | all 4 shims |

### CarPlay shim (patches/blmjcicarplay/)

| File | Key functions | What it does |
|------|---------------|-------------|
| `main.cpp` | `on_load()`, `in_carplay_launcher()` | Constructor: gates on process, loads hud_config, installs fatal signal handler |
| `devmgr_shim.cpp` | PLT shims for `IdentifyData` | Intercepts CarPlay messages, extracts nav bytes at offset 0x5204 |
| `nav.cpp` | `classify()`, distance conversion | Parses Apple maneuver → Mazda HUD icon, handles MPH/KMH |
| `patch.h` | `g_enabled`, logging macros | Master header with function declarations |
| `hud/hud_send.cpp` | `sender_main()`, `read_splim()`, `roundabout_icon()` | 2 Hz HUD write loop, seqlock, speed limit read, Vietnamese normalization |

### AA shim (patches/blmjciaapa/)

| File | Key functions | What it does |
|------|---------------|-------------|
| `hud/hud.cpp` | `read_hud_config()`, `compute_turn_icon()` | Main HUD logic, reads hud_config |
| `hud/hud_nav.h` | `roundabout_icon()`, `map_distance_unit()` | Icon mapping, AA unit → Mazda unit |

---

## 13. Gotchas and hard-won lessons

### Never use `pkill -f` for splim

The grep pattern matches the killing process itself. Use `ps | grep '[s]plim' | awk '{print $1}'`
with the bracket trick, or `pid_of()` as in `usb_run.sh`.

### `-lrt` is required

POSIX timer functions (`timer_create`, `timer_settime`) live in `librt.so` on the
CMU's glibc. Without `-lrt`, the shim loads but crashes at runtime with
undefined symbols. This is easy to miss because modern desktop Linux has these
in libc.

### The hud_share mechanism is load-bearing

v2.6.0-beta shipped a CarPlay shim built from a stripped source that removed the
entire hud_share.h mechanism. This caused:
- **Bug: speed limit broken** — CarPlay couldn't read `/tmp/hud_oem_speed`
- **Bug: HUD flickering** — no `/tmp/hud_carplay_active` marker, so the navi shim
  kept writing blank frames interleaved with CarPlay's real frames

The fix: rebuild from the correct `mazda-hud-unified` source that has all cooperative
mechanisms intact.

### Docker required for macOS builds

The M3 toolchain binaries are Linux x86-64 ELF. They can't run on macOS directly.
Build inside Docker:
```bash
docker run --rm -v "$(pwd):/src" -w /src ubuntu:22.04 bash -c "make blmjcicarplay"
```

### Clean `.d` files between checkouts

If you switch between source checkouts, stale `.d` dependency files may reference
old paths and cause "No rule to make target" errors. Run `find . -name '*.d' -delete`
before rebuilding.

### id_rsa_cmu must never be committed

The SSH private key for CMU access is in `.gitignore`. SSH: port 36000, user `cmu`,
key `id_rsa_cmu`.

### CMU clock starts at 1970

The RTC resets to epoch at every boot until a GPS fix arrives. This is why
`hud_share.h` treats future timestamps as stale (clock jump safety) and why
`usb_run.sh` uses sequence numbers instead of timestamps for log folders.

### sm.conf has two variants

Non-WCP units use `/jci/sm/sm.conf`. WCP-only units (board_type=2) use
`/jci/sm/sm_WCP.conf`. The installer patches both if present, but only the
active one (determined by `get_board_type.sh`) gets the LD_PRELOAD injections.

### Flash wear

The rootfs eMMC has limited write endurance. All runtime state goes to tmpfs (`/tmp`).
Persistent config goes to `/data_persist/` (a separate partition with wear leveling).
The installer remounts rootfs read-write only during install and remounts read-only
immediately after.
