# Mazda CMU CarPlay-HUD Toolkit — Español

Navegación turn-by-turn de **Apple CarPlay** en el **Head-Up Display** del cuadro de instrumentos para Mazda CMU150 (firmware 74.00.324) — con indicador correcto de límite de velocidad en **km/h** para el mercado europeo.

**Compatible con:** CX-5 KF, CX-8, CX-9 (2016-2023) y vehículos de la misma plataforma con firmware EU.

**Traducciones:** [English](README.md) · [Українська](README.uk.md) · [Deutsch](README.de.md) · [Português](README.pt.md)

---

## Qué hace este toolkit

Basado en el shim `LD_PRELOAD` [KidMixer/mazda-carplay-hud](https://github.com/KidMixer/mazda-carplay-hud) construido por la comunidad, con dos añadidos para vehículos europeos:

1. **Corrección km/h** — parche de una línea en el código fuente (`displaySpeedUnit = 2` en vez de `1`, enum VBS `km/h` en vez de `mph`). Sin esto, un HUD EU renderiza un cartel de `50 km/h` que viene del shim como `≈80 km/h` tras conversión mile→km.
2. **Daemon-espejo del límite de velocidad** — pequeño script shell que escucha pasivamente el stream HUD de `svcjcinavi.so` OEM y copia el límite *actual* en los frames keep-alive del propio shim. Sin esto, el shim sobrescribe el slot de velocidad con `0` cada 500 ms y el valor muere a `---` entre actualizaciones OEM.

Todo lo demás es bit-por-bit el build original de KidMixer.

---

## Requisitos

- Mazda CMU150, firmware `74.00.324`, versión EU (verificar: `cat /jci/version.ini` en el CMU)
- Memoria USB (≥1 GB, formateada FAT32)
- Un ordenador con Wi-Fi (macOS, Linux o Windows 10+)
- Hotspot Wi-Fi en tu CMU (viene con dongles CarPlay inalámbricos) o el setup root+SSH funcionando

## Contenido

```
mazda-hud-toolkit/
├── toolkit.sh              # menú macOS/Linux
├── toolkit.bat             # menú Windows (necesita OpenSSH integrado)
├── id_rsa_cmu              # generada por la opción B en el primer uso (NO viene incluida)
├── files/
│   ├── libpatch-blmjcicarplay.so         # PURE KidMixer .so (md5 0ce29da4…)
│   ├── libpatch-blmjcicarplay-splim.so   # mi .so parcheado — corrección km/h + guard read_splim (md5 faf82efb…)
│   ├── install.sh                        # instalador original de KidMixer
│   ├── uninstall.sh                      # desinstalador original
│   ├── splim_bridge.sh                   # mi daemon-espejo del límite de velocidad (v16)
│   ├── splim_udpd_start.sh               # auto-launcher usado por el shim
│   └── usb_unlock/                       # payload MP3-XSS para acceso root
└── backups/                              # creado por la opción 2 del menú
```

## Menú (tanto `toolkit.sh` como `toolkit.bat`)

| # | Acción |
|---|---|
| **1** | **Crear memoria USB** — formatea una USB (FAT32, etiqueta MZD) con el desbloqueo MP3-XSS (botón SSH) **y** el parche HUD (`hud-mod/`). En el coche, el menú en pantalla ofrece **SSH**, **HUD+** (instalar), **HUD-** (eliminar) y **HUD?** (comprobar), para instalar el parche sin portátil. |
| **2** | **Backup del CMU** — descarga por SSH un archivo con todos los ficheros que toca un parche a `backups/YYYYMMDD_HHMMSS/`. Ejecuta esto antes de instalar. |
| **3** | **Rollback** — elimina **todos** los parches HUD: CarPlay + Android Auto, ilshyma v16 con su daemon, KidMixer y oem-aa-mod. Vuelve al estado de fábrica, reinicia y confirma. |
| **4** | **Instalar parche HUD (CarPlay + Android Auto)** — un solo parche para ambos teléfonos: flechas y distancia para CarPlay y Android Auto, más el cartel de límite de velocidad desde la navegación de serie (necesita la SD de navegación). Cada archivo se verifica por md5. El toolkit reinicia la unidad, espera SSH y comprueba que los 4 módulos cargaron. Fuente: [mazda-carplay-hud `unified-carplay-aa`](https://github.com/ilshyma/mazda-carplay-hud/tree/unified-carplay-aa). La línea de nombre de calle no aparece en HUDs EU. |
| **B** | **Configurar clave SSH** — setup único para el flujo SSH (opciones 2 / 3 / 4). Genera `id_rsa_cmu` si no existe e instala su mitad pública en `authorized_keys` del CMU usando la contraseña de un solo uso `cmu:jci` del desbloqueo USB XSS. Solo necesario en un ordenador nuevo. |
| **A** | **Avanzado** — validar instalación, chequeo SSH, dump diagnóstico y parches antiguos solo-CarPlay (v16, pure KidMixer, legacy) con sus herramientas. |


### Instalar el parche HUD desde la USB (sin portátil)

La USB de la opción 1 también lleva el parche CarPlay + Android Auto (`hud-mod/`). En el coche, ábrela normalmente: Media → USB → toca un MP3. El menú arriba de la pantalla tiene tres botones adicionales:

- **HUD+** instala el parche. Tócalo, luego el botón rojo de confirmación. La unidad se reinicia sola tras ~30 s.
- **HUD-** lo elimina, vuelve al stock. Confirmación igual.
- **HUD?** comprueba que cada parte esté activa: CarPlay, Android Auto, Navi/velocidad.

Cada botón termina con un mensaje en pantalla. Si empieza con **ERROR** o **CHECK S1**, fotografíalo y envíalo. Contiene un código de error, versión de firmware, región y qué hacer. Cada intento recibe su propia carpeta numerada en la USB, `hud-mod/logs/001_install_<fecha>/`, con el mismo texto (`RESULT.txt`), log completo (`run.log`) y snapshot del sistema (`system.txt`). Envía esa carpeta junto con la foto.

## Dos formas de instalar

| | **A. Solo USB** _(por defecto — nada que escribir)_ | **B. Instalación SSH desde tu ordenador** |
|---|---|---|
| Qué haces en el coche | Insertas la USB → tocas **Install** en el diálogo. | Insertas la USB → tocas **SSH** en el menú XSS. |
| Qué corre en el CMU | El parche se instala automáticamente desde la USB. | Un pequeño `sshd` arranca en `192.168.53.1:36000`. |
| Qué haces en tu ordenador | Nada. | Ejecutas **opciones 2 / 4** de este toolkit por SSH. |
| ¿Necesita clave SSH? | No. | Sí — genérala una vez con la opción **B** abajo. |
| ¿Necesita la USB? | Sí, en cada instalación. | Sí, una vez por arranque del CMU (para reactivar SSH — el CMU mata `sshd` al reiniciar). |

Elige A si solo quieres el mod HUD. Elige B si también quieres backups, auto-validación, diagnóstico o las variantes antiguas solo-CarPlay (menú `L` / `P` / `X`).

### A. Solo USB (recomendado para la mayoría)

1. Ejecuta **opción 1** en tu ordenador — crea la USB.
2. Inserta la USB en el coche — espera ~30 s. Aparece un diálogo con **Install / Uninstall / Check Status** automáticamente (el scanner reflash del CMU se activa vía payloads `.up`). Si no aparece nada: Media → USB → toca cualquier mp3 — el menú XSS de respaldo tiene botones **HUD+ / HUD- / HUD?**.
3. Toca **Install**. La pantalla se apaga ~2 min mientras la unidad reinicia — es normal, no apagues el contacto.
4. Listo. Inicia navegación en CarPlay o Android Auto; la flecha debe aparecer en el HUD.

### B. Instalación SSH desde tu ordenador (usuarios avanzados)

1. **Crea la USB** — ejecuta **opción 1**.
2. **Activa SSH en el CMU** — inserta la USB en el coche, Media → USB → toca cualquier mp3 → toca **SSH** en el overlay XSS. Aparecen logs. (sshd ahora escucha en `192.168.53.1:36000`. Muere en cada arranque — repite este paso tras cada reinicio.)
3. **Conéctate al Wi-Fi del CMU** en tu ordenador (`CMU-XX:XX:...` o `MAZDA-xxx`).
4. **Configura la clave SSH — una vez por ordenador:** ejecuta **opción B**. El toolkit genera `id_rsa_cmu`, instala la mitad pública en el CMU usando la contraseña de un solo uso `jci` y verifica el login por clave. Introduces la contraseña exactamente una vez.
5. **Verifica + backup** — Avanzado → **S** (chequeo SSH), luego **opción 2** (backup).
6. **Instala** — ejecuta **opción 4**. Cada archivo se verifica por md5, el CMU reinicia, el toolkit espera a que SSH vuelva y auto-valida los 4 shims. (Tras el reinicio, repite el paso 2 cuando el toolkit lo pida — para que SSH esté activo para la validación.)
7. **Prueba** — inicia una sesión de navegación en CarPlay o Android Auto. La flecha de maniobra debe aparecer en el HUD; el slot de límite de velocidad debe mostrar el valor OEM actual (mapa + cámara TSR).

> **La clave SSH NO viene incluida** — el release público no tiene `id_rsa_cmu`. La opción **B** la crea localmente y la instala en el CMU. La clave privada nunca sale de tu ordenador; el lado CMU guarda la mitad pública en `/data_persist/.../authorized_keys` para que sobreviva a los reinicios.

## Notas y limitaciones

- El shim usa solo `LD_PRELOAD` — el `blmjcicarplay.so` original *nunca* se modifica en disco. El rootfs de solo lectura no puede ser "brikeado"; en el peor caso, un reboot devuelve la unidad al stock.
- El daemon-espejo NO dispara ningún request NNG. Solo escucha lo que el servicio OEM (`svcjcinavi.so`) ya emite en el bus D-Bus. Así el HUD queda lo más cerca posible del comportamiento stock.
- Flechas de guía de carril (`SetRecommLaneReq`) NO están implementadas — Apple no transmite datos de carril por el canal iAP2; solo el stream de video CarPlay los lleva.
- Los nombres de calles cirílicos se renderizan correctamente; el apóstrofo ucraniano (`’`) actualmente aparece como `?` porque la fuente del HUD OEM no tiene ese glifo — limitación OEM.
- La compilación se hizo con `-DCARPLAY_VN_NORMALIZE=1` (normalización de diacríticos vietnamitas). Inofensivo en cirílico/latín.

## Bajo el capó

- Shim base: **KidMixer/mazda-carplay-hud v2.0.0** — [fuente](https://github.com/KidMixer/mazda-carplay-hud), AGPL-3.0.
- Un único cambio en el código: `hud/hud_send.cpp` línea 561, valor `displaySpeedUnit` `1 → 2` (enum VBS: `1 = mph`, `2 = km/h`).
- Daemon-espejo: nuestro script shell de ~60 líneas; observa pasivamente llamadas a `com.jci.vbs.navi.SetHUDDisplayMsgReq` cuyo sender NO es nuestro shim, y escribe `<km/h> <unix_ts>` en `/data_persist/splim`. Refrescado cada 3 s; TTL 3600 s.
- El shim lee `/data_persist/splim` en cada frame keep-alive; si está fresco, incluye el valor; si vacío/stale, envía `0`.

## Windows: ¿`toolkit.bat` lanza errores de parser? Usa Git Bash

Si `toolkit.bat` en Windows muestra `'t' is not recognized`, `Missing expression after ','`, `cannot find batch label` o similar — `cmd.exe` en algunas versiones de Windows se atraganta parseando el .bat. El toolkit en sí está bien; el atajo más rápido es ejecutar `toolkit.sh` a través de Git Bash:

1. Instala **Git for Windows** — https://git-scm.com/download/win (un clic, ~50 MB).
2. Abre **Git Bash** desde el menú Inicio.
3. `cd` a la carpeta del toolkit, por ejemplo: `cd /c/Users/<tu_usuario>/Downloads/mazda-hud-toolkit/mazda-hud-toolkit`
4. Ejecuta: `bash toolkit.sh`

Todo excepto **Crear memoria USB** (opción 1) funciona completo vía Git Bash — backup, instalar, rollback, validar, Bootstrap de clave SSH. Para crear la USB usa `toolkit.bat` opción 1 en el mismo Windows, o formatea manualmente (FAT32, etiqueta `MZD`) y copia `files/usb_unlock/` + `files/unified/` → `hud-mod/`.

## Soporte

Si SSH no conecta en el puerto 36000, el `sshd` fue eliminado por el rootfs read-only al arrancar. Repite USB → XSS → SSH.

Si el bootstrap por contraseña (**opción B**) dice *"Permission denied"*, la contraseña es incorrecta. El desbloqueo USB XSS pone `cmu:jci` — teclea `jci` (minúsculas, tres letras) en el prompt. Si sigue fallando, el USB no se activó — repite el paso 2 (USB → XSS → SSH) y vuelve a intentar B.

Si el HUD sigue en blanco tras instalar, verifica con Avanzado → **V** primero; luego entra por SSH y comprueba `ps | grep sm_svclauncher | grep jciCARPLAY` — el proceso `L_jciCARPLAY` debe estar corriendo con `LD_PRELOAD` en su `/proc/PID/environ`.
