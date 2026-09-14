# Mazda CMU CarPlay-HUD Toolkit — Español

Navegación turno-a-turno de **Apple CarPlay** en el **Head-Up Display** del cuadro de instrumentos para Mazda CMU150 (firmware 74.00.324) — con indicador correcto de límite de velocidad en **km/h** para el mercado europeo.

**Compatible con:** CX-5 KF, CX-8, CX-9 (2016-2023) y unidades de la misma plataforma con firmware EU.

**Traducciones:** [English](README.md) · [Українська](README.uk.md) · [Deutsch](README.de.md) · [Português](README.pt.md)

---

## Qué hace este kit

Basado en el mod comunitario [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) con dos añadidos para vehículos del mercado europeo:

1. **Corrección km/h** — parche de una línea en el código fuente (`displaySpeedUnit = 2` en lugar de `1`, es decir el enum VBS `km/h` en lugar de `mph`). Sin esta corrección, un HUD europeo dibuja una señal de `50 km/h` que viene del shim como `≈80 km/h` tras la conversión mile→km.
2. **Daemon-espejo del límite de velocidad** — un pequeño script de shell que escucha pasivamente el flujo HUD original de `svcjcinavi.so` y copia el valor *actual* del límite en los frames keep-alive del propio shim. Sin él, el shim sobrescribe el slot de velocidad con `0` cada 500 ms y el valor cae a `---` entre actualizaciones OEM.

Todo lo demás es bit-a-bit el original de KidMixer.

---

## Requisitos

- Mazda CMU150, firmware `74.00.324`, versión EU (verificar: `cat /jci/version.ini`)
- USB flash drive (≥1 GB, formato FAT32)
- Un ordenador con Wi-Fi (macOS, Linux o Windows 10+)
- Wi-Fi hotspot en el CMU (viene con dongles de CarPlay inalámbrico) o el setup root+SSH descrito abajo

## Contenido

```
mazda-hud-toolkit/
├── toolkit.sh              # menú macOS/Linux
├── toolkit.bat             # menú Windows (necesita OpenSSH integrado)
├── id_rsa_cmu              # clave SSH para la cuenta `cmu` del head unit
├── files/
│   ├── libpatch-blmjcicarplay.so         # PURE KidMixer .so (md5 0ce29da4…)
│   ├── libpatch-blmjcicarplay-splim.so   # mi .so parcheado — corrección km/h + guard read_splim (md5 faf82efb…)
│   ├── install.sh                        # instalador original de KidMixer
│   ├── uninstall.sh                      # desinstalador original
│   ├── splim_bridge.sh                   # mi daemon-espejo del límite de velocidad (v16)
│   ├── splim_udpd_start.sh               # auto-launcher usado por el shim
│   └── usb_unlock/                       # payload MP3-XSS para acceso root
└── backups/                          # creado por la opción 2 del menú
```

## Menú (tanto `toolkit.sh` como `toolkit.bat`)

| # | Acción |
|---|---|
| **1** | **Crear USB de desbloqueo** — formatea una USB como FAT32/MZD y copia el payload MP3-XSS que da acceso root+SSH al CMU. Usa la técnica [mzd-connect-1-root](https://github.com/mzd-evo/mzd-connect-1-root). Inserta la USB en el head unit, toca cualquier MP3, luego toca **SSH** en el menú XSS que aparece — `sshd` arranca en el puerto 36000. |
| **2** | **Backup del CMU** — descarga por SSH un archivo con todos los archivos que toca el instalador (`sm.conf`, `sm_WCP.conf`, `devmgr_config_master.xml`, `blmjcicarplay.so`, `/data_persist/cp-hud-mod/`, `version.ini`) en `backups/YYYYMMDD_HHMMSS/`. Ejecuta esto ANTES de instalar. |
| **3** | **Instalar PURE KidMixer Patch** — build upstream sin modificar. Rápido y seguro, pero en vehículos EU tiene un problema conocido: el slot de límite de velocidad muestra ~80 km/h por una conversión mile→km del propio shim, y muere a `---` entre actualizaciones OEM. Úsalo si quieres el comportamiento upstream puro o como base antes de pasar a la opción 4. |
| **4** | **Instalar ilshyma HUD Patch** ★ recomendado — despliegue en 3 pasos: (a) `install.sh` original añade `LD_PRELOAD` a `sm.conf` y pone `NaviSupported=TRUE`, (b) superpone mi `.so` parcheado (corrección km/h + guard `read_splim` contra future-ts), (c) copia el daemon-espejo v16 y su auto-launcher. Termina con un reboot; espera ~2 min y luego restablece SSH vía la USB. |
| **5** | **Rollback completo** — mata mi daemon, elimina mis extras, ejecuta el `uninstall.sh` original que restaura `sm.conf` y `NaviSupported=FALSE` desde los backups `.bak_precphud`. Termina con un reboot. |
| **9** | Chequeo de conexión SSH |

## Procedimiento primera vez

1. Formatea una USB, ejecuta **opción 1** para prepararla.
2. Inserta la USB en el coche. Media → USB → toca cualquier MP3 → espera al overlay XSS abajo de la pantalla → toca **SSH**. Aparecen logs verdes, listo.
3. Conecta tu ordenador al Wi-Fi del CMU (`CMU-XX:XX:...` o `MAZDA-xxx`).
4. Ejecuta **opción 9** para verificar SSH, luego **opción 2** para hacer backup.
5. Ejecuta **opción 4** (ilshyma HUD Patch) para instalar. Espera al reboot.
6. En el head unit, repite el paso 2 (USB → SSH) para reactivar SSH tras el reboot.
7. Prueba — inicia una sesión de navegación en CarPlay. La flecha de maniobra debe aparecer en el HUD; el slot de límite de velocidad debe mostrar el valor OEM actual (mapa + cámara TSR).

## Notas y limitaciones

- El shim usa solo `LD_PRELOAD` — el `blmjcicarplay.so` original *nunca* se modifica en disco. El rootfs de solo lectura no puede ser "brikeado"; en el peor caso, un reboot devuelve la unidad al stock.
- El daemon-espejo NO dispara ningún request NNG. Solo escucha lo que el servicio OEM (`svcjcinavi.so`) ya emite en el bus D-Bus. Así el HUD queda lo más cerca posible del comportamiento stock.
- Flechas de guía de carril (`SetRecommLaneReq`) NO están implementadas — Apple no transmite datos de carril por el canal iAP2; solo el stream de video CarPlay los lleva.
- Los nombres de calles cirílicos se renderizan correctamente; el apóstrofo ucraniano (`’`) actualmente aparece como `?` porque la fuente del HUD OEM no tiene ese glifo — limitación OEM.
- La compilación se hizo con `-DCARPLAY_VN_NORMALIZE=1` (normalización de diacríticos vietnamitas). Inofensivo en cirílico/latín.

## Bajo el capó

- Shim base: **KidMixer/mazda-carplay-hud v2.0.0** — [fuente](https://github.com/KidMixer/mazda-carplay-hud), AGPL-3.0.
- Un único cambio en el código: `hud/hud_send.cpp` línea 561, valor `displaySpeedUnit` `1 → 2` (enum VBS: `1 = mph`, `2 = km/h`).
- Daemon-espejo: nuestro script shell de ~60 líneas; observa pasivamente llamadas a `com.jci.vbs.navi.SetHUDDisplayMsgReq` cuyo sender NO es nuestro shim, y escribe `<km/h> <unix_ts>` en `/data_persist/splim`. Refrescado cada 3 s para satisfacer el chequeo stale del shim; TTL 3600 s.
- El shim lee `/data_persist/splim` en cada frame keep-alive; si está fresco, incluye el valor; si vacío/stale, envía `0`.

## Soporte

Si SSH no conecta en el puerto 36000, el `sshd` fue eliminado por el rootfs read-only al arrancar. Repite USB → XSS → SSH.

Si el HUD sigue en blanco tras instalar, verifica con opción 9 primero; luego entra por SSH y comprueba `ps | grep sm_svclauncher | grep jciCARPLAY` — el proceso `L_jciCARPLAY` debe estar corriendo con `LD_PRELOAD` en su `/proc/PID/environ`.
