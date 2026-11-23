# Диагностика HUD + CarPlay — пошаговая инструкция

> Mazda 6 CMU150 FW 74.00.324 EU — все конфиги идеальны, шимы загружены (checker: ALL OK),
> штатная навигация отображается на HUD (стрелки на стекле), но от CarPlay — ничего.
> Нужно найти где обрывается runtime цепочка.

---

## Что понадобится

- USB-флешка с HUD toolkit (подготовленная через `toolkit.sh` → опция 1)
- iPhone с Lightning/USB-C кабелем
- Ноутбук с установленным Claude Code
- SSH-ключ `id_rsa_cmu` (генерируется при первом подключении через `toolkit.sh` → опция B)

---

## Этап 1. Подготовка USB-флешки (если ещё не готова)

На Mac/Linux запустить:

```bash
cd mazda-hud-toolkit
./toolkit.sh
```

Выбрать **опцию 1** — "Create USB stick". Скрипт:
- Отформатирует флешку в FAT32 с меткой "MZD"
- Скопирует MP3-файлы, XSS-скрипты и hud-mod на флешку
- Создаст .up файлы для автоматического запуска (CVE-2024-8359)

---

## Этап 2. В машине — запуск XSS меню

1. **Вставить USB-флешку** в порт головного устройства
2. Подождать **~30 секунд** — должен появиться диалог Install/Uninstall/Check
   (срабатывает автоматически через .up инъекцию в сканер обновлений прошивки)

**Если диалог НЕ появился** (альтернативный путь через MP3):
1. На экране: **Media → USB**
2. Тапнуть на **любой MP3** из списка (a.mp3, b.mp3...)
3. Появится **XSS меню** внизу экрана с кнопками:
   `SSH` `HUD+` `HUD-` `HUD?` `Probe` `Term` `Keyb` `Logs` `RST` `X`

---

## Этап 3. Включение SSH

1. В XSS меню нажать кнопку **SSH**
2. Скрипт выполнит 6 методов включения sshd (img/script/iframe/form/window.open/fetch)
3. На экране появятся результаты — подождать **5 секунд**
4. SSH включён. Пароли установлены:
   - `root:mazda`
   - `cmu:jci`

> SSH добавляется в автозапуск (`stage_wifi.sh`), поэтому переживёт перезагрузку.

---

## Этап 4. Подключение к WiFi CMU

1. На ноутбуке открыть **настройки WiFi**
2. Найти сеть **MAZDA-xxx** (точка доступа CMU)
3. Подключиться к ней
4. IP адрес CMU: **192.168.53.1**

---

## Этап 5. Первое SSH-подключение (bootstrap ключа)

Если ключ `id_rsa_cmu` ещё не создан, запустить:

```bash
cd mazda-hud-toolkit
./toolkit.sh
```

Выбрать **опцию B** — "Bootstrap SSH key". Скрипт:
- Сгенерирует RSA-2048 ключ `id_rsa_cmu`
- Скопирует публичный ключ на CMU через `ssh-copy-id`
- Пароль при запросе: **jci**

После этого все подключения по ключу, без пароля.

**Ручное подключение** (если toolkit.sh недоступен):

```bash
ssh -o StrictHostKeyChecking=no -o PubkeyAcceptedAlgorithms=+ssh-rsa \
    -i id_rsa_cmu -p 36000 cmu@192.168.53.1
```

Или по паролю:

```bash
ssh -o StrictHostKeyChecking=no -p 36000 cmu@192.168.53.1
# пароль: jci
```

---

## Этап 6. ПЕРЕД диагностикой — запустить маршрут CarPlay

> **ВАЖНО**: сначала маршрут, потом SSH-диагностика!

1. Подключить **iPhone по USB-кабелю**
2. CarPlay должен появиться на экране CMU
3. Открыть **Apple Maps** (или Google Maps)
4. Задать любой маршрут и нажать **«Поехали»**
5. Убедиться что на экране CMU видны **стрелки поворотов**
6. Маршрут должен быть **активен** во время всех следующих шагов

---

## Этап 7. SSH-диагностика (по порядку вероятности)

Подключиться по SSH (см. Этап 5), затем выполнять команды по порядку.

### Шаг 1. Маркер `/tmp/hud_carplay_active` — шим перехватывает?

```bash
cat /tmp/hud_carplay_active
```

| Результат | Значение | Дальше |
|-----------|----------|--------|
| Пусто или нет файла | Шим blmjcicarplay **НЕ** перехватывает CarPlay навигацию | → Шаг 2 |
| Есть timestamp | Шим работает, данные идут. Проблема дальше по цепочке | → Шаг 4 |

---

### Шаг 2. Шим загружен? Конструктор запустился?

```bash
P=$(ps | awk '/L_jciCARPLAY/{print $1; exit}')
echo "PID: $P"
cat /proc/$P/maps | grep libpatch
ls -la /proc/$P/fd 2>/dev/null | grep dbus
```

| Результат | Значение |
|-----------|----------|
| `libpatch-blmjcicarplay.so` НЕТ в maps | Шим вообще не загружен — проблема в sm.conf |
| Есть в maps, но нет dbus fd | Конструктор шима не открыл D-Bus соединение |
| Есть в maps И есть dbus fd | Шим загружен и подключён — проблема в перехвате |

---

### Шаг 3. D-Bus мониторинг — шим посылает SetHUDDisplayMsgReq?

При активном CarPlay маршруте:

```bash
timeout 15 dbus-monitor --address unix:path=/tmp/dbus_service_socket \
  "type='method_call',interface='com.jci.vbs.navi'" 2>&1 | head -60
```

| Результат | Значение |
|-----------|----------|
| Видно `SetHUDDisplayMsgReq` | Шим посылает данные, но VBS не передаёт на CAN |
| Пусто | Шим не посылает. Проблема в перехвате IdentifyData |

Дополнительно — послушать что приходит от CarPlay:

```bash
timeout 15 dbus-monitor --address unix:path=/tmp/dbus_service_socket \
  "interface='com.jci.carplay'" 2>&1 | head -100
```

---

### Шаг 4. Конфликт с merge shim (если hud_carplay_active есть)

Merge шим (svcjcinavi) может блокировать CarPlay фреймы.

```bash
cat /tmp/hud_oem_speed
```

Проверить sender — все вызовы от svcjcinavi и ноль от jciCARPLAY?

```bash
timeout 15 dbus-monitor --address unix:path=/tmp/dbus_service_socket \
  "type='method_call',member='SetHUDDisplayMsgReq'" 2>&1 | head -80
```

---

### Шаг 5. Принудительный тест — послать HUD-фрейм вручную

**Это самый важный тест.** Проверяет путь VBS → CAN → HUD ECU независимо от шимов:

```bash
dbus-send --address=unix:path=/tmp/dbus_service_socket \
  --dest=com.jci.vbs.navi \
  /com/jci/vbs/navi \
  com.jci.vbs.navi.SetHUDDisplayMsgReq \
  uint16:3 uint16:200000 uint8:1 string:"TEST STREET" uint16:50 uint8:1 boolean:true
```

Параметры: поворот налево (3), дистанция 200м, улица "TEST STREET", спидлимит 50, guidancePoint=true.

| Результат | Значение |
|-----------|----------|
| На стекле появилась стрелка + "TEST STREET" | VBS→CAN→HUD работает. Проблема точно в шиме |
| Ничего на стекле | VBS не передаёт — проверить сигнатуру через introspect |

Если ничего — получить точную сигнатуру:

```bash
dbus-send --address=unix:path=/tmp/dbus_service_socket \
  --print-reply --dest=com.jci.vbs.navi \
  /com/jci/vbs/navi \
  org.freedesktop.DBus.Introspectable.Introspect
```

---

### Шаг 6. GetHUDIsInstalled — что думает система

```bash
dbus-send --address=unix:path=/tmp/dbus_hmi_socket \
  --print-reply --dest=com.jci.navi2IHU \
  /com/jci/navi2IHU \
  com.jci.navi2IHU.HUDSettings.GetHUDIsInstalled
```

Если `FALSE` → система не знает что HUD установлен (но раз штатная нави показывает
стрелки на HUD, этот флаг может не влиять на путь через VBS).

---

### Шаг 7. hud_probe.sh (полная запись D-Bus трафика)

Если hud_probe.sh доступен на CMU:

```bash
sh /data_persist/oem-aa-mod/hud_probe.sh start
```

Поездить с активным CarPlay маршрутом 2–3 минуты, затем:

```bash
sh /data_persist/oem-aa-mod/hud_probe.sh stop
```

Файлы для анализа:
- `dbus_service.log` — все SetHUDDisplayMsgReq вызовы
- `state.log` — PID'ы, скорость, флаг hud_carplay_active

---

## Порядок вероятности проблемы

1. **Шим загружен, но конструктор не запустился** — `/tmp/hud_carplay_active` пуст
   при активном CarPlay маршруте. Нужен лог конструктора / strace
2. **PLT interposition не сработал** — IdentifyData не перехвачен →
   dbus-monitor не покажет SetHUDDisplayMsgReq от jciCARPLAY
3. **CarPlay не шлёт nav data** — NaviSupported=TRUE, но iPhone не
   перенегоциировал capabilities → отключить/подключить телефон
4. **D-Bus call проходит, но VBS игнорирует** — ручной тест (Шаг 5) покажет
5. **Merge shim конфликт** — OEM фреймы затирают CarPlay фреймы

---

## Быстрый чеклист для Claude Code

Подключившись по SSH, Claude должен выполнить по порядку:

```bash
# 1. Маркер CarPlay
cat /tmp/hud_carplay_active

# 2. Шим в памяти + D-Bus fd
P=$(ps | awk '/L_jciCARPLAY/{print $1; exit}'); echo "PID=$P"
cat /proc/$P/maps | grep libpatch
ls -la /proc/$P/fd 2>/dev/null | grep dbus

# 3. D-Bus мониторинг (15 сек)
timeout 15 dbus-monitor --address unix:path=/tmp/dbus_service_socket \
  "type='method_call',member='SetHUDDisplayMsgReq'" 2>&1

# 4. Ручной тест HUD
dbus-send --address=unix:path=/tmp/dbus_service_socket \
  --dest=com.jci.vbs.navi /com/jci/vbs/navi \
  com.jci.vbs.navi.SetHUDDisplayMsgReq \
  uint16:3 uint16:200000 uint8:1 string:"TEST" uint16:50 uint8:1 boolean:true

# 5. HUD installed?
dbus-send --address=unix:path=/tmp/dbus_hmi_socket \
  --print-reply --dest=com.jci.navi2IHU /com/jci/navi2IHU \
  com.jci.navi2IHU.HUDSettings.GetHUDIsInstalled
```

По результатам каждого шага — решать что дальше.
