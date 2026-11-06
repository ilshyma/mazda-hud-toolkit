# Mazda CarPlay HUD Toolkit

Apple CarPlay turn-by-turn navigation on the instrument-cluster HUD for Mazda CMU150 (firmware `74.00.324`) — with a correct **km/h** speed limit for the European market.

**Site:** [mazda-toolkit.monodev.org](https://mazda-toolkit.monodev.org)

**Downloads:** [Latest release](../../releases/latest)

**Applies to:** CX-5 KF, CX-8, CX-9 (2018) and same-platform units with EU firmware.

## v2.5 — What's new

- **Wireless CarPlay (WCP)** — optional: enable native WiFi-based CarPlay on CMU150 units that shipped with wired-only. iPhone connects via 2.4 GHz WiFi after the first wired pairing. Enable/disable from the USB menu. Based on community research (Kenatia, ASH8, ingbrzy).
- **RHD roundabout fix** — left-hand-traffic HUD exit arrows were mirrored. Fixed in source (`hud_send.cpp`), auto-detected from the CarPlay protocol. Thanks to [@shannang97](https://github.com/shannang97) for the report and binary-level analysis ([#1](../../issues/1)).

## Based on

- [KidMixer/mazda-carplay-hud v2.0.0](https://github.com/KidMixer/mazda-carplay-hud) (AGPL-3.0)
- [VitaliyKurokhtin/oem-aa-mod](https://github.com/VitaliyKurokhtin/oem-aa-mod) — Android Auto HUD support

## What's different

One source-line patch on top of the KidMixer build:

- `hud/hud_send.cpp` — `displaySpeedUnit` VBS enum `1 (mph)` → `2 (km/h)` for European HUDs.

Plus a small ~60-line shell daemon that passively mirrors the OEM speed-limit stream from `svcjcinavi.so` into `/data_persist/splim`, so the shim's keep-alive frames don't stomp on the OEM value with `0`.

Full patched shim source: [ilshyma/mazda-carplay-hud eu-fix branch](https://github.com/ilshyma/mazda-carplay-hud/tree/eu-fix).

## License

AGPL-3.0 (inherited from the upstream KidMixer/mazda-carplay-hud).
