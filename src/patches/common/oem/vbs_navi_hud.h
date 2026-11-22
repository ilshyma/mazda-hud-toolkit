// Shared com.jci.vbs.navi HUD wire structs + the AAP frame sentinel.
//
// These are the on-wire layouts the OEM navigation HUD path uses
// (libjcivbsnaviclient marshals them onto com.jci.vbs.navi). Both the
// blmjciaapa vbs transport (which sends them) and the svcjcinavi merge
// patch (which interposes the OEM setter and rewrites them) need the
// exact same definitions, so they live here.
//
// All offsets hand-derived from the Ghidra decompile
// (libjcivbsnaviclient / libjcimod_navigation). Re-verify after any
// OEM firmware update.

#ifndef LIBPATCH_COMMON_OEM_VBS_NAVI_HUD_H
#define LIBPATCH_COMMON_OEM_VBS_NAVI_HUD_H

#include <stdint.h>

// 12-byte com.jci.vbs.navi HUD frame, signature (uqyqyy). Field
// offsets verified against VBS_NAVI_HUD_Display_s_t_pack:
// u32@0, u16@4, u8@6, u16@8, u8@10, u8@11 (sizeof == 12 with the
// natural pad byte at offset 7).
struct VbsNaviHudDisplay {
    uint32_t nextManeuverInfo;
    uint16_t distanceValue;
    uint8_t  distanceUnit;
    uint16_t displaySpeedLimit;
    uint8_t  displaySpeedUnit;
    uint8_t  text_ID3;
};

// 8-byte com.jci.vbs.navi.tmc street-name struct, signature (sy):
// char*@0, u8@4. The library transcodes UTF-8 -> UCS-2 and pages it
// internally; we just hand it a NUL-terminated C string.
struct VbsNaviHudMsg2 {
    const char *guidancePointName;
    uint8_t     syncBit;
};

// Reserved speedLimit value marking a HUD frame as AAP-originated.
//
// The blmjciaapa svcnavi transport stamps this into the speedLimit
// field of the GuidanceChangedForHUD signal it emits; svcjcinavi's
// merge patch keys on it (in displaySpeedLimit of the packed frame)
// to tell our frames from the OEM nav engine's. 0xFFFF is the max
// uint16 and the HUD firmware's own "no speed limit" sentinel, so a
// stock (un-merged) svcjcinavi renders it as a blank speed rather
// than a bogus number — confirmed on-device.
//
// On the GuidanceChangedForHUD signal wire the speedLimit arg is
// int32; 65535 round-trips into this uint16 field unchanged.
static const uint16_t kAapSpeedSentinel = 0xFFFF;

#endif  // LIBPATCH_COMMON_OEM_VBS_NAVI_HUD_H
