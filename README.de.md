# Mazda CMU CarPlay-HUD Toolkit — Deutsch

Turn-by-turn-Navigation von **Apple CarPlay** auf dem **Head-Up Display** des Kombiinstruments für Mazda CMU150 (Firmware 74.00.324) — mit korrekter **km/h**-Geschwindigkeitsbegrenzungsanzeige.

**Passend für:** CX-5 KF, CX-8, CX-9 (2018) und andere Fahrzeuge derselben Plattform.

**Übersetzungen:** [English](README.md) · [Українська](README.uk.md) · [Español](README.es.md) · [Português](README.pt.md)

---

## Was dieses Toolkit macht

Basierend auf dem Community-Mod [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) mit zwei Ergänzungen:

1. **km/h-Fix** — Einzeilen-Patch im Quellcode (`displaySpeedUnit = 2` statt `1`, d.h. VBS-Enum `km/h` statt `mph`). Ohne diesen Fix zeichnet das HUD ein vom Shim kommendes `50 km/h`-Schild als `≈80 km/h` nach Meilen→km-Umrechnung.
2. **Geschwindigkeitsbegrenzungs-Spiegel-Daemon** — ein kleines Shell-Skript, das passiv den OEM-HUD-Stream von `svcjcinavi.so` beobachtet und den *aktuellen* Wert in die keep-alive-Frames des Shim kopiert. Ohne ihn überschreibt der Shim den Speed-Slot alle 500 ms mit `0`, und der Wert fällt zwischen OEM-Updates auf `---`.

Alles andere ist bitgenau das Original von KidMixer.

---

## Voraussetzungen

- Mazda CMU150, Firmware `74.00.324` (Verifikation: `cat /jci/version.ini`)
- USB-Stick (≥1 GB, FAT32-formatiert)
- Ein Computer mit WLAN (macOS, Linux oder Windows 10+)
- WLAN-Hotspot am CMU (bei wireless-CarPlay-Dongles) oder das unten beschriebene funktionierende Root+SSH-Setup

## Inhalt

```
mazda-hud-toolkit/
├── toolkit.sh              # macOS/Linux-Menü
├── toolkit.bat             # Windows-Menü (benötigt integriertes OpenSSH)
├── id_rsa_cmu              # SSH-Schlüssel für `cmu`-Konto am Head Unit
├── files/
│   ├── libpatch-blmjcicarplay.so     # ARM-Shim mit km/h-Fix
│   ├── install.sh                    # originaler KidMixer-Installer
│   ├── uninstall.sh                  # originaler KidMixer-Uninstaller
│   ├── splim_bridge.sh               # unser Spiegel-Daemon
│   ├── splim_udpd_start.sh           # Auto-Launcher, den der Shim ruft
│   └── usb_unlock/                   # MP3-XSS-Payload für Root-Zugriff
└── backups/                          # von Menüpunkt 2 erstellt
```

## Menü (sowohl `toolkit.sh` als auch `toolkit.bat`)

| # | Aktion |
|---|---|
| **1** | **USB-Unlock-Stick erstellen** — formatiert einen USB-Stick als FAT32/MZD und kopiert die MP3-XSS-Payload, die Root+SSH am CMU freischaltet. Nutzt die [mzd-connect-1-root](https://github.com/mzd-evo/mzd-connect-1-root)-Technik. USB einstecken, beliebige MP3 antippen, dann **SSH** im erscheinenden XSS-Overlay — `sshd` startet auf Port 36000. |
| **2** | **CMU-Backup** — lädt per SSH ein Archiv aller vom Installer angefassten Dateien herunter (`sm.conf`, `sm_WCP.conf`, `devmgr_config_master.xml`, `blmjcicarplay.so`, `/data_persist/cp-hud-mod/`, `version.ini`) nach `backups/YYYYMMDD_HHMMSS/`. VOR der Installation ausführen. |
| **3** | **KidMixer-Patch installieren** — dreistufige Bereitstellung: (a) führt das originale `install.sh` aus, das `LD_PRELOAD` zu `sm.conf` hinzufügt und `NaviSupported=TRUE` setzt, (b) überlagert unseren `.so` mit km/h-Fix, (c) kopiert Spiegel-Daemon und Auto-Launcher. Endet mit Reboot; ~2 min warten, dann SSH per USB wiederherstellen. |
| **4** | **Kompletter Rollback** — beendet unseren Daemon, entfernt unsere Extras, führt das originale `uninstall.sh` aus, das `sm.conf` und `NaviSupported=FALSE` aus den `.bak_precphud`-Backups wiederherstellt. Endet mit Reboot. |
| **9** | SSH-Verbindungscheck |

## Erste Installation

1. USB-Stick formatieren, **Option 1** ausführen, um ihn vorzubereiten.
2. USB ins Auto einstecken. Media → USB → beliebige MP3 antippen → auf XSS-Overlay unten am Bildschirm warten → **SSH** antippen. Grüne Logs erscheinen, fertig.
3. Computer mit dem CMU-WLAN verbinden (`CMU-XX:XX:...` oder `MAZDA-xxx`).
4. **Option 9** zur SSH-Prüfung ausführen, dann **Option 2** für Backup.
5. **Option 3** zur Installation ausführen. Auf Reboot warten.
6. Am Head Unit Schritt 2 wiederholen (USB → SSH), um SSH nach dem Reboot wieder zu aktivieren.
7. Testen — CarPlay-Navigation starten. Der Manöverpfeil sollte auf dem HUD erscheinen; der Speed-Limit-Slot sollte den aktuellen OEM-Wert (Karte + TSR-Kamera) zeigen.

## Hinweise und Einschränkungen

- Der Shim verwendet nur `LD_PRELOAD` — das originale `blmjcicarplay.so` wird auf der Festplatte NIE verändert. Das Read-only-Rootfs kann nicht "gebricked" werden; im schlimmsten Fall stellt ein Reboot den Auslieferungszustand wieder her.
- Der Spiegel-Daemon löst KEINE NNG-Requests aus. Er hört nur, was der OEM-Navigationsdienst (`svcjcinavi.so`) bereits auf dem D-Bus emittiert. So bleibt das HUD-Verhalten so nah wie möglich am Original.
- Fahrspurführungs-Pfeile (`SetRecommLaneReq`) sind NICHT implementiert — Apple überträgt keine Spurdaten über den iAP2-Sidechannel; nur der CarPlay-Videostream enthält sie.
- Kyrillische Straßennamen werden korrekt gerendert; das ukrainische Apostroph (`’`) erscheint derzeit als `?`, weil die OEM-HUD-Schriftart dieses Glyph nicht hat — OEM-Einschränkung.
- Der Build wurde mit `-DCARPLAY_VN_NORMALIZE=1` (vietnamesische Diakritik-Normalisierung) erstellt. Harmlos bei Kyrillisch/Latein.

## Unter der Haube

- Basis-Shim: **KidMixer/mazda-carplay-hud v2.0.0** — [Quellcode](https://github.com/KidMixer/mazda-carplay-hud), AGPL-3.0.
- Eine einzige Quellcode-Änderung: `hud/hud_send.cpp` Zeile 561, `displaySpeedUnit`-Wert `1 → 2` (VBS-Enum: `1 = mph`, `2 = km/h`).
- Spiegel-Daemon: unser ~60-zeiliges Shell-Skript; beobachtet passiv `com.jci.vbs.navi.SetHUDDisplayMsgReq`-Aufrufe, deren Sender NICHT unser Shim ist, und schreibt `<km/h> <unix_ts>` nach `/data_persist/splim`. Alle 3 s aktualisiert, um den Stale-Check des Shim zufriedenzustellen; TTL 3600 s.
- Der Shim liest `/data_persist/splim` bei jedem keep-alive-Frame; ist die Datei frisch, wird der Wert eingefügt; ist sie leer/stale, wird `0` gesendet.

## Support

Wenn SSH auf Port 36000 nicht verbindet, wurde `sshd` am Head Unit vom Read-only-Rootfs beim Boot beendet. USB → XSS → SSH-Schritt wiederholen.

Wenn das HUD nach der Installation leer bleibt, zuerst mit Option 9 verifizieren; dann per SSH einloggen und `ps | grep sm_svclauncher | grep jciCARPLAY` prüfen — der `L_jciCARPLAY`-Prozess muss mit `LD_PRELOAD` in seinem `/proc/PID/environ` laufen.
