// SPDX-License-Identifier: AGPL-3.0-or-later
//
// User-facing HUD configuration read from /data_persist/hud_config.
//
// This is a SEPARATE config from libpatch.conf (which carries developer-
// oriented tuning). hud_config carries USER preferences set by the
// toolkit installer:
//
//   traffic_side = RHT | LHT     right-hand / left-hand traffic
//   speed_unit   = KMH | MPH     speed-limit and distance display unit
//
// File format: same key=value as libpatch.conf (config.h::parse_file).
// Missing file or keys fall back to defaults (RHT, KMH).
//
// Header-only, same convention as hud_share.h / config.h.

#ifndef LIBPATCH_COMMON_HUD_CONFIG_H
#define LIBPATCH_COMMON_HUD_CONFIG_H

#include <stdio.h>
#include <string.h>
#include <strings.h>

namespace hud_config {

constexpr const char *kHudConfigPath = "/data_persist/hud_config";

struct HudUserConfig {
    bool lht;       // true = left-hand traffic (UK/JP/AU), false = RHT (default)
    bool mph;       // true = miles/h, false = km/h (default)
    bool loaded;
};

inline HudUserConfig &instance()
{
    static HudUserConfig cfg = { false, false, false };
    return cfg;
}

inline void load()
{
    HudUserConfig &c = instance();
    if (c.loaded) return;
    c.loaded = true;

    FILE *f = fopen(kHudConfigPath, "re");
    if (!f) return;

    char line[128];
    while (fgets(line, sizeof(line), f)) {
        size_t n = strlen(line);
        while (n > 0 && (line[n-1] == '\n' || line[n-1] == '\r')) line[--n] = '\0';
        char *p = line;
        while (*p == ' ' || *p == '\t') ++p;
        if (*p == '\0' || *p == '#') continue;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = '\0';
        char *key = p;
        char *val = eq + 1;
        // trim key
        char *ke = eq;
        while (ke > key && (ke[-1] == ' ' || ke[-1] == '\t')) --ke;
        *ke = '\0';
        // trim val
        while (*val == ' ' || *val == '\t') ++val;
        char *ve = val + strlen(val);
        while (ve > val && (ve[-1] == ' ' || ve[-1] == '\t')) --ve;
        *ve = '\0';

        if (strcasecmp(key, "traffic_side") == 0) {
            c.lht = (strcasecmp(val, "LHT") == 0);
        } else if (strcasecmp(key, "speed_unit") == 0) {
            c.mph = (strcasecmp(val, "MPH") == 0);
        }
    }
    fclose(f);
}

inline bool is_lht()  { return instance().lht; }
inline bool is_mph()  { return instance().mph; }

} // namespace hud_config

#endif // LIBPATCH_COMMON_HUD_CONFIG_H
