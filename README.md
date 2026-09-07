# Mazda CarPlay HUD Toolkit

Apple CarPlay turn-by-turn navigation on the instrument-cluster HUD for Mazda CMU150 (firmware `74.00.324`) — with a correct **km/h** speed limit for the European market.

**Site:** [mazda-toolkit.monodev.org](https://mazda-toolkit.monodev.org)

**Downloads:** [Latest release](../../releases/latest)

**Applies to:** CX-5 KF, CX-8, CX-9 (2018) and same-platform units with EU firmware.

## Based on

- [KidMixer/mazda-carplay-hud v2.0.0](https://github.com/KidMixer/mazda-carplay-hud) (AGPL-3.0)

## What's different

One source-line patch on top of the KidMixer build:

- `hud/hud_send.cpp` — `displaySpeedUnit` VBS enum `1 (mph)` → `2 (km/h)` for European HUDs.

Plus a small ~60-line shell daemon that passively mirrors the OEM speed-limit stream from `svcjcinavi.so` into `/data_persist/splim`, so the shim's keep-alive frames don't stomp on the OEM value with `0`.

Full patched shim source: [ilshyma/mazda-carplay-hud eu-fix branch](https://github.com/ilshyma/mazda-carplay-hud/tree/eu-fix).

## License

AGPL-3.0 (inherited from the upstream KidMixer/mazda-carplay-hud).
