# Mazda CMU CarPlay-HUD Toolkit

Turn-by-turn navigation from **Apple CarPlay** on the instrument-cluster **Head-Up Display** for Mazda CMU150 (firmware 74.00.324) — with a correct **km/h** speed-limit indicator for the European market.

**Applies to:** CX-5 KF, CX-8, CX-9 (2018) and same-platform units with EU firmware.

**Translations:** [Українська](README.uk.md) · [Español](README.es.md) · [Deutsch](README.de.md) · [Português](README.pt.md)

---

## What this toolkit does

Based on the community-built [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) `LD_PRELOAD` shim, with two additions for European vehicles:

1. **km/h fix** — one-line source patch (`displaySpeedUnit = 2` instead of `1`, i.e. VBS enum `km/h` instead of `mph`). Without this fix, an EU HUD renders a `50 km/h` sign coming from the shim as `≈80 km/h` after mile→km conversion.
2. **Speed-limit mirror daemon** — a small shell script that passively watches the OEM `svcjcinavi.so` HUD stream and copies the *current* speed limit into the shim's own keep-alive frames. Without this, the shim overwrites the speed slot with `0` every 500 ms and the value dies to `---` between OEM updates.

Everything else is bit-for-bit the original KidMixer build.

---

## Requirements

- Mazda CMU150, firmware `74.00.324`, EU flavor (verify: `cat /jci/version.ini` on CMU)
- USB flash drive (≥1 GB, FAT32-formatted)
- A computer with Wi-Fi (macOS, Linux, or Windows 10+)
- Wi-Fi hotspot on your CMU (comes with wireless-CarPlay dongles) or the working root+SSH setup described below

## Contents

```
mazda-hud-toolkit/
├── toolkit.sh              # macOS/Linux menu
├── toolkit.bat             # Windows menu (needs built-in OpenSSH)
├── id_rsa_cmu              # SSH key for the `cmu` account on the head unit
├── files/
│   ├── libpatch-blmjcicarplay.so         # PURE KidMixer .so (md5 0ce29da4…)
│   ├── libpatch-blmjcicarplay-splim.so   # my patched .so — km/h fix + read_splim guard (md5 faf82efb…)
│   ├── install.sh                        # original KidMixer installer
│   ├── uninstall.sh                      # original KidMixer uninstaller
│   ├── splim_bridge.sh                   # my speed-limit mirror daemon (v16)
│   ├── splim_udpd_start.sh               # auto-launcher hooked by the shim
│   └── usb_unlock/                       # MP3-XSS payload for root access
└── backups/                          # created by option 2 of the menu
```

## Menu (both `toolkit.sh` and `toolkit.bat`)

| # | Action |
|---|---|
| **1** | **Create USB unlock stick** — formats a USB drive as FAT32/MZD and copies the MP3-XSS payload that gives you root+SSH on the CMU. Uses [mzd-connect-1-root](https://github.com/mzd-evo/mzd-connect-1-root) technique. Insert the stick in the head unit, tap any of the MP3 files, then tap **SSH** in the XSS overlay that appears — `sshd` starts on port 36000 with the key in this folder. |
| **2** | **Backup CMU state** — SSH-fetches an archive of every file the installer touches (`sm.conf`, `sm_WCP.conf`, `devmgr_config_master.xml`, `blmjcicarplay.so`, `/data_persist/cp-hud-mod/`, `version.ini`) into `backups/YYYYMMDD_HHMMSS/`. Run this *before* installing anything. |
| **3** | **Install PURE KidMixer Patch** — plain upstream build. Fast and safe, but on EU vehicles has a known issue: the HUD speed-limit slot shows ~80 km/h from a mile→km conversion the shim does on its own, and dies to `---` between OEM updates. Use this only if you want plain upstream behaviour or as a baseline before switching to option 4. |
| **4** | **Install ilshyma HUD Patch** ★ recommended — three-step deploy: (a) vanilla `install.sh` writes the `LD_PRELOAD` line to `sm.conf` and sets `NaviSupported=TRUE`, (b) my patched `.so` (km/h fix + `read_splim` future-ts guard) is overlaid, (c) the v16 speed-mirror daemon + auto-launcher are copied. Ends with a reboot; wait ~2 min then re-establish SSH via the USB stick. |
| **5** | **Full rollback** — kills my daemon, removes my extras, runs the vanilla `uninstall.sh` which restores `sm.conf` and `NaviSupported=FALSE` from `.bak_precphud` backups made by `install.sh`. Ends with a reboot. |
| **9** | SSH health check |

## First-time procedure

1. Format a USB stick, run **option 1** to prepare it.
2. Insert the stick in the car. Media → USB → tap any MP3 → wait for the XSS overlay at the bottom of the screen → tap **SSH**. Log messages appear; done.
3. Connect your computer to the CMU Wi-Fi (`CMU-XX:XX:...` or `MAZDA-xxx`).
4. Run **option 9** to verify SSH works, then **option 2** to back up.
5. Run **option 4** (ilshyma HUD Patch) to install. Wait for reboot.
6. On the head unit, repeat step 2 (USB → SSH) to re-enable SSH after the reboot.
7. Test — start a CarPlay navigation session. The maneuver arrow should appear on the HUD; the speed-limit slot should show the current OEM value (from map + TSR camera).

## Notes and limitations

- The shim uses `LD_PRELOAD` only — the OEM `blmjcicarplay.so` is *never* modified on disk. The read-only rootfs cannot be bricked; worst case, a reboot returns the unit to stock.
- The speed-mirror daemon does **not** trigger any NNG requests. It only listens to what the OEM navigation service (`svcjcinavi.so`) already broadcasts on the D-Bus service bus. So the HUD stays as close to stock behaviour as possible.
- Lane guidance arrows (`SetRecommLaneReq`) are **not** implemented — Apple does not transmit lane data over the iAP2 side channel; only the CarPlay video stream carries it.
- Cyrillic street names render correctly; the Ukrainian apostrophe (`’`) currently prints as `?` because the OEM HUD font lacks that glyph — this is an OEM limitation.
- The build was made with `-DCARPLAY_VN_NORMALIZE=1` (Vietnamese diacritic stripping for the HUD font). Harmless on Cyrillic/Latin.

## Under the hood

- Base shim: **KidMixer/mazda-carplay-hud v2.0.0** — [source](https://github.com/KidMixer/mazda-carplay-hud), AGPL-3.0.
- One source change on top: `hud/hud_send.cpp` line 561, `displaySpeedUnit` value `1 → 2` (VBS enum: `1 = mph`, `2 = km/h`).
- Speed-mirror daemon: our own ~60-line shell script; passively watches `com.jci.vbs.navi.SetHUDDisplayMsgReq` calls whose sender is *not* our own shim, and writes `<km/h> <unix_ts>` to `/data_persist/splim`. Rebuilt every 3 s to keep the shim's stale-check happy; TTL 3600 s so a genuine dead-zone longer than an hour clears the value.
- The shim reads `/data_persist/splim` on every keep-alive frame; if fresh, includes the value; if empty/stale, sends `0` (behaving like the stock installer's build).

## Support

If SSH refuses to connect on port 36000, the `sshd` on the head unit was killed by the read-only rootfs at boot. Re-run the USB → XSS → SSH step and it comes back up.

If the HUD stays blank after install, verify with option 9 first; then SSH in and check `ps | grep sm_svclauncher | grep jciCARPLAY` — the `L_jciCARPLAY` process must be running with `LD_PRELOAD` in its `/proc/PID/environ`.
