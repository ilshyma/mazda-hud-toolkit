# Mazda CMU CarPlay-HUD Toolkit — Deutsch

Turn-by-turn-Navigation von **Apple CarPlay** auf dem **Head-Up Display** des Instrumententrägers für Mazda CMU150 (Firmware 74.00.324) — mit korrekter **km/h**-Geschwindigkeitslimit-Anzeige für den europäischen Markt.

**Passt für:** CX-5 KF, CX-8, CX-9 (2016-2023) und Fahrzeuge derselben Plattform mit EU-Firmware.

**Übersetzungen:** [English](README.md) · [Українська](README.uk.md) · [Español](README.es.md) · [Português](README.pt.md)

---

## Was dieses Toolkit macht

Basiert auf dem Community-Build [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) `LD_PRELOAD`-Shim mit zwei Erweiterungen für europäische Fahrzeuge:

1. **km/h-Fix** — einzeiliger Source-Patch (`displaySpeedUnit = 2` statt `1`, VBS-Enum `km/h` statt `mph`). Ohne diesen Fix rendert ein EU-HUD ein vom Shim kommendes `50 km/h`-Schild als `≈80 km/h` nach mile→km-Umrechnung.
2. **Spiegel-Daemon fürs Speed-Limit** — kleines Shell-Skript, das den OEM-`svcjcinavi.so`-HUD-Stream passiv beobachtet und das *aktuelle* Speed-Limit in die eigenen Keep-Alive-Frames des Shim kopiert. Ohne diesen überschreibt der Shim den Speed-Slot alle 500 ms mit `0` und der Wert stirbt zwischen OEM-Updates zu `---`.

Alles andere ist bit-identisch zum original KidMixer-Build.

---

## Voraussetzungen

- Mazda CMU150, Firmware `74.00.324`, EU-Variante (prüfen: `cat /jci/version.ini` am CMU)
- USB-Stick (≥1 GB, FAT32-formatiert)
- Computer mit WLAN (macOS, Linux oder Windows 10+)
- WLAN-Hotspot am CMU (bei wireless-CarPlay-Dongles vorhanden) oder funktionierendes Root+SSH-Setup

## Inhalt

```
mazda-hud-toolkit/
├── toolkit.sh              # macOS/Linux-Menü
├── toolkit.bat             # Windows-Menü (benötigt integriertes OpenSSH)
├── id_rsa_cmu              # von Option B beim ersten Lauf erzeugt (NICHT im Paket)
├── files/
│   ├── libpatch-blmjcicarplay.so         # PURE KidMixer .so (md5 0ce29da4…)
│   ├── libpatch-blmjcicarplay-splim.so   # mein gepatchtes .so — km/h-Fix + read_splim-Guard (md5 faf82efb…)
│   ├── install.sh                        # originaler KidMixer-Installer
│   ├── uninstall.sh                      # originaler KidMixer-Uninstaller
│   ├── splim_bridge.sh                   # mein Spiegel-Daemon fürs Speed-Limit (v16)
│   ├── splim_udpd_start.sh               # Auto-Launcher, den der Shim ruft
│   └── usb_unlock/                       # MP3-XSS-Payload für Root-Zugriff
└── backups/                              # von Menüpunkt 2 erstellt
```

## Menü (sowohl `toolkit.sh` als auch `toolkit.bat`)

| # | Aktion |
|---|---|
| **1** | **USB-Stick erstellen** — formatiert einen USB-Stick (FAT32, Label MZD) mit dem MP3-XSS-Unlock (SSH-Button) **und** dem HUD-Patch (`hud-mod/`). Im Auto bietet das On-Screen-Menü **SSH**, **HUD+** (installieren), **HUD-** (entfernen) und **HUD?** (prüfen), sodass der Patch ohne Laptop installiert werden kann. |
| **2** | **CMU-Backup** — SSH-lädt ein Archiv aller vom Patch angefassten Dateien nach `backups/YYYYMMDD_HHMMSS/`. Vor der Installation ausführen. |
| **3** | **Rollback** — entfernt **jeden** HUD-Patch: CarPlay + Android Auto, ilshyma v16 mit Speed-Daemon, KidMixer und oem-aa-mod. Zurück zum Werkszustand, Reboot und Bestätigung. |
| **4** | **HUD-Patch installieren (CarPlay + Android Auto)** — ein Patch für beide Phones: Pfeile und Entfernung für CarPlay und Android Auto plus Speed-Limit-Zeichen aus der Werksnavigation (benötigt die Navi-SD-Karte). Jede Datei wird md5-verifiziert. Das Toolkit rebootet die Einheit, wartet auf SSH und prüft, dass alle 4 Teile geladen sind. Quelle: [mazda-carplay-hud `unified-carplay-aa`](https://github.com/ilshyma/mazda-carplay-hud/tree/unified-carplay-aa). Die Straßennamen-Zeile wird auf EU-HUDs nicht angezeigt. |
| **B** | **SSH-Key Bootstrap** — einmalige Einrichtung für den SSH-Flow (Optionen 2 / 3 / 4). Generiert `id_rsa_cmu` falls fehlend und installiert die öffentliche Hälfte in `authorized_keys` am CMU mithilfe des Einmalpassworts `cmu:jci` vom USB XSS-Unlock. Nur auf einem neuen Rechner erforderlich. |
| **A** | **Erweitert** — Installation validieren, SSH-Check, Diagnose-Dump sowie ältere CarPlay-only-Patches (v16, pure KidMixer, legacy) mit ihren Tools. |


### HUD-Patch vom USB-Stick installieren (ohne Laptop)

Der Stick aus Option 1 trägt auch den CarPlay + Android Auto HUD-Patch (`hud-mod/`). Im Auto wie gewohnt öffnen: Media → USB → MP3 antippen. Das Menü oben am Bildschirm hat drei zusätzliche Buttons:

- **HUD+** installiert den Patch. Antippen, dann rote Bestätigung drücken. Die Einheit rebootet nach ca. 30 s von selbst.
- **HUD-** entfernt ihn, zurück zum Stock. Bestätigung genauso.
- **HUD?** prüft, dass alle Teile aktiv sind: CarPlay, Android Auto, Navi/Speed.

Jeder Button endet mit einer Meldung am Bildschirm. Beginnt sie mit **ERROR** oder **CHECK S1**, bitte fotografieren und senden. Sie enthält einen Fehlercode, die Firmware-Version, die Region und was zu tun ist. Jeder Versuch bekommt einen nummerierten Ordner am Stick, `hud-mod/logs/001_install_<datum>/`, mit demselben Text (`RESULT.txt`), vollem Log (`run.log`) und einem Systemsnapshot (`system.txt`). Diesen Ordner zusammen mit dem Foto senden.

## Zwei Installationswege

| | **A. Nur USB** _(Standard — nichts zu tippen)_ | **B. SSH-Installation vom Computer** |
|---|---|---|
| Was Sie im Auto tun | Stick einlegen → **Install** im Dialog antippen. | Stick einlegen → **SSH** im XSS-Menü antippen. |
| Was am CMU läuft | Patch wird automatisch vom USB installiert. | Kleiner `sshd` startet auf `192.168.53.1:36000`. |
| Was Sie am Computer tun | Nichts. | **Optionen 2 / 4** des Toolkits über SSH ausführen. |
| SSH-Key nötig? | Nein. | Ja — einmalig mit Option **B** unten generieren. |
| USB-Stick nötig? | Ja, bei jeder Installation. | Ja, einmal pro CMU-Boot (um SSH wieder einzuschalten — CMU killt `sshd` beim Reboot). |

Wählen Sie A, wenn Sie nur den HUD-Mod wollen. Wählen Sie B, wenn Sie auch Backups, Auto-Validierung, Diagnostik oder die älteren CarPlay-only-Varianten (Menü `L` / `P` / `X`) brauchen.

### A. Nur USB (empfohlen für die meisten)

1. **Option 1** am Computer ausführen — erstellt den USB-Stick.
2. Stick ins Auto einlegen — ~30 s warten. Dialog mit **Install / Uninstall / Check Status** erscheint automatisch (CMU reflash scanner wird über `.up`-Payloads getriggert). Erscheint nichts: Media → USB → beliebige MP3 — das XSS-Fallback-Menü hat **HUD+ / HUD- / HUD?**-Buttons.
3. **Install** antippen. Bildschirm wird für ~2 min dunkel während die Einheit rebootet — das ist normal, Zündung nicht ausschalten.
4. Fertig. CarPlay- oder Android-Auto-Navigation starten; der Pfeil sollte am HUD erscheinen.

### B. SSH-Installation vom Computer (Power-User)

1. **USB-Stick erstellen** — **Option 1** ausführen.
2. **SSH am CMU einschalten** — Stick ins Auto einlegen, Media → USB → MP3 antippen → **SSH** im XSS-Overlay antippen. Log-Meldungen erscheinen. (sshd lauscht jetzt auf `192.168.53.1:36000`. Er wird bei jedem Boot gekillt — diesen Schritt nach jedem Neustart wiederholen.)
3. **CMU-WLAN beitreten** am Computer (`CMU-XX:XX:...` oder `MAZDA-xxx`).
4. **SSH-Key bootstrappen — einmal pro Computer:** **Option B** ausführen. Das Toolkit generiert `id_rsa_cmu`, pusht die öffentliche Hälfte am CMU über das Einmalpasswort `jci` und verifiziert den Key-basierten Login. Das Passwort geben Sie genau einmal ein.
5. **Prüfen + Backup** — Erweitert → **S** (SSH-Check), dann **Option 2** (Backup).
6. **Installieren** — **Option 4** ausführen. Jede Datei wird md5-verifiziert, der CMU rebootet, das Toolkit wartet bis SSH wiederkommt und auto-validiert alle 4 Shims. (Nach dem Reboot Schritt 2 wiederholen, wenn das Toolkit danach fragt — damit SSH für den Validate-Schritt wieder läuft.)
7. **Testen** — CarPlay- oder Android-Auto-Navigation starten. Der Manöverpfeil sollte am HUD erscheinen; der Speed-Limit-Slot sollte den aktuellen OEM-Wert zeigen (Karte + TSR-Kamera).

> **Der SSH-Key wird NICHT mitgeliefert** — der Public Release enthält kein `id_rsa_cmu`. Option **B** erzeugt ihn lokal und installiert ihn am CMU. Der Private Key verlässt niemals Ihren Computer; die CMU-Seite hält die öffentliche Hälfte in `/data_persist/.../authorized_keys`, damit sie Reboots überlebt.

## Hinweise und Einschränkungen

- Der Shim verwendet nur `LD_PRELOAD` — das originale `blmjcicarplay.so` wird auf der Festplatte NIE verändert. Das Read-only-Rootfs kann nicht "gebricked" werden; im schlimmsten Fall stellt ein Reboot den Auslieferungszustand wieder her.
- Der Spiegel-Daemon löst KEINE NNG-Requests aus. Er hört nur, was der OEM-Navigationsdienst (`svcjcinavi.so`) bereits auf dem D-Bus emittiert. So bleibt das HUD-Verhalten so nah wie möglich am Original.
- Fahrspurführungs-Pfeile (`SetRecommLaneReq`) sind NICHT implementiert — Apple überträgt keine Spurdaten über den iAP2-Sidechannel; nur der CarPlay-Videostream enthält sie.
- Kyrillische Straßennamen werden korrekt gerendert; das ukrainische Apostroph (`’`) erscheint derzeit als `?`, weil die OEM-HUD-Schriftart dieses Glyph nicht hat — OEM-Einschränkung.
- Der Build wurde mit `-DCARPLAY_VN_NORMALIZE=1` (vietnamesische Diakritik-Normalisierung) erstellt. Harmlos bei Kyrillisch/Latein.

## Unter der Haube

- Basis-Shim: **KidMixer/mazda-carplay-hud v2.0.0** — [Quellcode](https://github.com/KidMixer/mazda-carplay-hud), AGPL-3.0.
- Eine einzige Quellcode-Änderung: `hud/hud_send.cpp` Zeile 561, `displaySpeedUnit`-Wert `1 → 2` (VBS-Enum: `1 = mph`, `2 = km/h`).
- Spiegel-Daemon: unser ~60-zeiliges Shell-Skript; beobachtet passiv `com.jci.vbs.navi.SetHUDDisplayMsgReq`-Aufrufe, deren Sender NICHT unser Shim ist, und schreibt `<km/h> <unix_ts>` nach `/data_persist/splim`. Alle 3 s aktualisiert; TTL 3600 s.
- Der Shim liest `/data_persist/splim` bei jedem keep-alive-Frame; ist die Datei frisch, wird der Wert eingefügt; ist sie leer/stale, wird `0` gesendet.

## Windows: `toolkit.bat` wirft Parser-Fehler? Nutze stattdessen Git Bash

Wenn `toolkit.bat` unter Windows `'t' is not recognized`, `Missing expression after ','`, `cannot find batch label` oder Ähnliches ausgibt, verschluckt sich `cmd.exe` auf manchen Windows-Builds beim Parsen der .bat. Das Toolkit selbst ist in Ordnung; der schnellste Workaround ist `toolkit.sh` über Git Bash:

1. Installiere **Git for Windows** — https://git-scm.com/download/win (ein Klick, ~50 MB).
2. Öffne **Git Bash** aus dem Startmenü.
3. `cd` in den Toolkit-Ordner, z. B. `cd /c/Users/<dein_user>/Downloads/mazda-hud-toolkit/mazda-hud-toolkit`
4. Starte: `bash toolkit.sh`

Alles außer **USB-Stick erstellen** (Option 1) läuft komplett über Git Bash — Backup, Installieren, Rollback, Validierung, Bootstrap SSH-Key. Für den USB-Schritt nutze entweder `toolkit.bat` Option 1 auf demselben Windows-Rechner oder formatiere den Stick manuell (FAT32, Label `MZD`) und kopiere `files/usb_unlock/` + `files/unified/` → `hud-mod/` darauf.

## Support

Wenn SSH auf Port 36000 nicht verbindet, wurde `sshd` am Head Unit vom Read-only-Rootfs beim Boot beendet. USB → XSS → SSH-Schritt wiederholen.

Wenn der Passwort-Bootstrap (**Option B**) *"Permission denied"* sagt, ist das Passwort falsch. Das USB XSS-Unlock setzt `cmu:jci` — am Prompt `jci` eingeben (Kleinbuchstaben, drei Zeichen). Klappt es immer noch nicht, hat der USB nicht ausgelöst — Schritt 2 (USB → XSS → SSH) wiederholen und B erneut probieren.

Wenn das HUD nach der Installation leer bleibt, zuerst mit Erweitert → **V** verifizieren; dann per SSH einloggen und `ps | grep sm_svclauncher | grep jciCARPLAY` prüfen — der `L_jciCARPLAY`-Prozess muss mit `LD_PRELOAD` in seinem `/proc/PID/environ` laufen.
