// SPDX-License-Identifier: AGPL-3.0-or-later
//
// HUD street-name transliteration.
//
// The Mazda HUD ECU font only has glyphs for Unicode code points below
// roughly U+0800 (verified on-device: 2-byte-UTF-8 letters like ư=U+01B0
// render; any 3-byte-UTF-8 letter like ễ=U+1EC5 renders as a blank
// space). Whole scripts in that 3-byte range therefore blank out (CJK,
// Thai, Indic, …) and can't be recovered — they have no sub-U+0800
// equivalent to fall back to.
//
// What CAN be recovered are the PRECOMPOSED LATIN letters of the Latin
// Extended Additional block (U+1E00..U+1EFF): each is a plain Latin
// letter plus diacritics, so it folds to a renderable base. We map every
// code point in that block to its base letter, keeping a renderable
// accent where the letter is defined by one (the breve/circumflex/horn
// forms ă â ê ô ơ ư and their capitals) and dropping only the marks
// the font can't draw:
//
//   ễ U+1EC5 -> ê     ớ U+1EDB -> ơ     ậ U+1EAD -> â
//   ḍ U+1E0D -> d     ṛ U+1E5B -> r     ẁ U+1E81 -> w
//
// so e.g. a name the font shows as "Nguy n Phư c" reads "Nguyên Phươc".
//
// Only the U+1E00..U+1EFF block is folded; every other byte — ASCII, the
// already-renderable ă/â/ê/ô/ơ/ư/đ, and any non-Latin ≥U+0800 text
// — passes through byte-for-byte, so there is no behaviour change outside
// that block. The whole CMU path already converts the name correctly
// (aap_service → blmjciaapa → svcjcinavi/vbs → the OEM
// SetHUD_Display_Msg2 iconv UTF-8→UCS2); the loss is purely the ECU font,
// so folding to a renderable base is the only lever we have. The fold
// never lengthens the string (a 3-byte sequence becomes ≤2 bytes;
// everything else keeps its length).
//
// Header-only: the patches/ tree compiles only patches/<name>/*.cpp, so
// shared inline code lives in headers (same convention as hud_nav.h).

#ifndef LIBPATCH_BLMJCIAAPA_HUD_TRANSLIT_H
#define LIBPATCH_BLMJCIAAPA_HUD_TRANSLIT_H

#include <stddef.h>
#include <stdint.h>

namespace hud_translit {

// Fold a precomposed Latin letter in the Latin Extended Additional block
// [U+1E00, U+1EFF] to its HUD-renderable base (< U+0800): the base
// letter, keeping a sub-U+0800 accent where the letter is defined by one
// (â ă ê ô ơ ư and capitals), otherwise the plain ASCII letter.
// Returns 0 for code points outside the block (caller passes those
// through unchanged). Indexed by (cp - 0x1E00); covers all 256 code
// points in the block.
inline uint32_t fold_base(uint32_t code_point)
{
    if (code_point < 0x1E00 || code_point > 0x1EFF) {
        return 0;
    }
    // Targets are all < U+0800 (1- or 2-byte UTF-8). The Latin-with-
    // mark-below/above rows (U+1E00..U+1E9F) fold to the plain ASCII
    // letter; the Vietnamese rows (U+1EA0..U+1EF9) keep the renderable
    // breve/circumflex/horn base and drop only the tone.
    static const uint16_t kBase[256] = {
        /* 1E00 */ 0x41,0x61,0x42,0x62,0x42,0x62,0x42,0x62, // Ḁḁ Ḃḃ Ḅḅ Ḇḇ
        /* 1E08 */ 0x43,0x63,0x44,0x64,0x44,0x64,0x44,0x64, // Ḉḉ Ḋḋ Ḍḍ Ḏḏ
        /* 1E10 */ 0x44,0x64,0x44,0x64,0x45,0x65,0x45,0x65, // Ḑḑ Ḓḓ Ḕḕ Ḗḗ
        /* 1E18 */ 0x45,0x65,0x45,0x65,0x45,0x65,0x46,0x66, // Ḙḙ Ḛḛ Ḝḝ Ḟḟ
        /* 1E20 */ 0x47,0x67,0x48,0x68,0x48,0x68,0x48,0x68, // Ḡḡ Ḣḣ Ḥḥ Ḧḧ
        /* 1E28 */ 0x48,0x68,0x48,0x68,0x49,0x69,0x49,0x69, // Ḩḩ Ḫḫ Ḭḭ Ḯḯ
        /* 1E30 */ 0x4B,0x6B,0x4B,0x6B,0x4B,0x6B,0x4C,0x6C, // Ḱḱ Ḳḳ Ḵḵ Ḷḷ
        /* 1E38 */ 0x4C,0x6C,0x4C,0x6C,0x4C,0x6C,0x4D,0x6D, // Ḹḹ Ḻḻ Ḽḽ Ḿḿ
        /* 1E40 */ 0x4D,0x6D,0x4D,0x6D,0x4E,0x6E,0x4E,0x6E, // Ṁṁ Ṃṃ Ṅṅ Ṇṇ
        /* 1E48 */ 0x4E,0x6E,0x4E,0x6E,0x4F,0x6F,0x4F,0x6F, // Ṉṉ Ṋṋ Ṍṍ Ṏṏ
        /* 1E50 */ 0x4F,0x6F,0x4F,0x6F,0x50,0x70,0x50,0x70, // Ṑṑ Ṓṓ Ṕṕ Ṗṗ
        /* 1E58 */ 0x52,0x72,0x52,0x72,0x52,0x72,0x52,0x72, // Ṙṙ Ṛṛ Ṝṝ Ṟṟ
        /* 1E60 */ 0x53,0x73,0x53,0x73,0x53,0x73,0x53,0x73, // Ṡṡ Ṣṣ Ṥṥ Ṧṧ
        /* 1E68 */ 0x53,0x73,0x54,0x74,0x54,0x74,0x54,0x74, // Ṩṩ Ṫṫ Ṭṭ Ṯṯ
        /* 1E70 */ 0x54,0x74,0x55,0x75,0x55,0x75,0x55,0x75, // Ṱṱ Ṳṳ Ṵṵ Ṷṷ
        /* 1E78 */ 0x55,0x75,0x55,0x75,0x56,0x76,0x56,0x76, // Ṹṹ Ṻṻ Ṽṽ Ṿṿ
        /* 1E80 */ 0x57,0x77,0x57,0x77,0x57,0x77,0x57,0x77, // Ẁẁ Ẃẃ Ẅẅ Ẇẇ
        /* 1E88 */ 0x57,0x77,0x58,0x78,0x58,0x78,0x59,0x79, // Ẉẉ Ẋẋ Ẍẍ Ẏẏ
        /* 1E90 */ 0x5A,0x7A,0x5A,0x7A,0x5A,0x7A,0x68,0x74, // Ẑẑ Ẓẓ Ẕẕ ẖẗ
        /* 1E98 */ 0x77,0x79,0x61,0x73,0x73,0x73,0x53,0x64, // ẘẙ ẚẛ ẜẝ ẞẟ
        /* 1EA0 */ 0x41,0x61,0x41,0x61,0xC2,0xE2,0xC2,0xE2, // Ạạ Ảả Ấấ Ầầ
        /* 1EA8 */ 0xC2,0xE2,0xC2,0xE2,0xC2,0xE2,0x102,0x103, // Ẩẩ Ẫẫ Ậậ Ắắ
        /* 1EB0 */ 0x102,0x103,0x102,0x103,0x102,0x103,0x102,0x103, // Ằằ Ẳẳ Ẵẵ Ặặ
        /* 1EB8 */ 0x45,0x65,0x45,0x65,0x45,0x65,0xCA,0xEA, // Ẹẹ Ẻẻ Ẽẽ Ếế
        /* 1EC0 */ 0xCA,0xEA,0xCA,0xEA,0xCA,0xEA,0xCA,0xEA, // Ềề Ểể Ễễ Ệệ
        /* 1EC8 */ 0x49,0x69,0x49,0x69,0x4F,0x6F,0x4F,0x6F, // Ỉỉ Ịị Ọọ Ỏỏ
        /* 1ED0 */ 0xD4,0xF4,0xD4,0xF4,0xD4,0xF4,0xD4,0xF4, // Ốố Ồồ Ổổ Ỗỗ
        /* 1ED8 */ 0xD4,0xF4,0x1A0,0x1A1,0x1A0,0x1A1,0x1A0,0x1A1, // Ộộ Ớớ Ờờ Ởở
        /* 1EE0 */ 0x1A0,0x1A1,0x1A0,0x1A1,0x55,0x75,0x55,0x75, // Ỡỡ Ợợ Ụụ Ủủ
        /* 1EE8 */ 0x1AF,0x1B0,0x1AF,0x1B0,0x1AF,0x1B0,0x1AF,0x1B0, // Ứứ Ừừ Ửử Ữữ
        /* 1EF0 */ 0x1AF,0x1B0,0x59,0x79,0x59,0x79,0x59,0x79, // Ựự Ỳỳ Ỵỵ Ỷỷ
        /* 1EF8 */ 0x59,0x79,0x4C,0x6C,0x56,0x76,0x59,0x79, // Ỹỹ Ỻỻ Ỽỽ Ỿỿ
    };
    return kBase[code_point - 0x1E00];
}

// Encode a code point <= U+07FF as 1 or 2 UTF-8 bytes into `out` (which
// must have room for 2). Returns the number of bytes written.
inline size_t encode_utf8(uint32_t code_point, char *out)
{
    if (code_point < 0x80) {
        out[0] = static_cast<char>(code_point);
        return 1;
    }
    out[0] = static_cast<char>(0xC0 | (code_point >> 6));
    out[1] = static_cast<char>(0x80 | (code_point & 0x3F));
    return 2;
}

// Fold the U+1E00..U+1EFF precomposed-Latin block in the NUL-terminated
// string `s` to renderable base letters, IN PLACE. Copies every other
// sequence verbatim; malformed bytes pass through one at a time. NULL is
// a no-op; the result is NUL-terminated.
//
// In-place is safe because the fold never lengthens the string: a folded
// code point is always a 3-byte input that re-encodes to ≤2 bytes, and
// every other sequence is rewritten at its own length, so the write
// cursor stays at or behind the read cursor for the whole pass and never
// clobbers a byte that hasn't been read yet.
inline void fold(char *str)
{
    if (str == nullptr) {
        return;
    }
    const unsigned char *read_ptr  = reinterpret_cast<const unsigned char *>(str);
    char                *write_ptr = str;   // invariant: write_ptr <= read_ptr
    bool                 saw_long_seq = false;  // any 3-/4-byte sequence seen yet?

    while (*read_ptr != '\0') {
        unsigned char lead = read_ptr[0];
        size_t        seq_len;

        // Classify the sequence by its lead byte. Only 3-byte sequences
        // can fall in the foldable block (U+1E00..U+1EFF ⊂ U+0800..U+FFFF),
        // so the 1-/2-/4-byte tiers short-circuit straight to the verbatim
        // copy below without decoding a code point or consulting the table.
        if (lead < 0x80) {
            // 1-byte, U+0000..U+007F — ASCII / Basic Latin. Renderable.
            seq_len = 1;
        } else if ((lead & 0xE0) == 0xC0 && (read_ptr[1] & 0xC0) == 0x80) {
            // 2-byte, U+0080..U+07FF — Latin-1 Supplement, Latin
            // Extended-A/B (incl. ă â ê ô ơ ư đ), IPA, Greek, Cyrillic,
            // Armenian, Hebrew, Arabic, Syriac, Thaana, NKo. All below
            // U+0800, so the HUD font renders them.
            seq_len = 2;
        } else if ((lead & 0xF0) == 0xE0 && (read_ptr[1] & 0xC0) == 0x80 &&
                   (read_ptr[2] & 0xC0) == 0x80) {
            // 3-byte, U+0800..U+FFFF — the only foldable tier. The HUD
            // font blanks all of it; the Latin Extended Additional block
            // (U+1E00..U+1EFF, precomposed Latin) folds to a renderable
            // base, while everything else here (CJK, Thai, Indic, Hangul,
            // Georgian, …) has no Latin base and is copied (stays blank).
            saw_long_seq = true;
            uint32_t code_point = ((lead & 0x0Fu) << 12) |
                                  ((read_ptr[1] & 0x3Fu) << 6) |
                                  (read_ptr[2] & 0x3Fu);
            uint32_t base_point = fold_base(code_point);
            if (base_point != 0) {
                // Base re-encodes to 1-2 bytes — strictly shorter than the
                // 3-byte input, so writing here can't clobber unread bytes.
                write_ptr += encode_utf8(base_point, write_ptr);
                read_ptr  += 3;
                continue;
            }
            seq_len = 3;
        } else if ((lead & 0xF8) == 0xF0 && (read_ptr[1] & 0xC0) == 0x80 &&
                   (read_ptr[2] & 0xC0) == 0x80 && (read_ptr[3] & 0xC0) == 0x80) {
            // 4-byte, U+10000..U+10FFFF — supplementary planes (emoji,
            // rare/historic CJK, …). Never renderable, nothing to fold.
            saw_long_seq = true;
            seq_len = 4;
        } else {
            // Invalid lead/continuation — pass the raw byte through.
            seq_len = 1;
        }

        // Until a 3-/4-byte sequence has been seen the string can't have
        // shrunk, so write_ptr == read_ptr and the bytes are already in
        // place — just advance. After that (saw_long_seq) a fold may have
        // pulled write_ptr behind read_ptr, so compact the bytes left;
        // write_ptr <= read_ptr makes this forward copy safe.
        if (saw_long_seq) {
            for (size_t byte_idx = 0; byte_idx < seq_len; ++byte_idx) {
                *write_ptr++ = static_cast<char>(read_ptr[byte_idx]);
            }
        } else {
            write_ptr += seq_len;
        }
        read_ptr += seq_len;
    }

    *write_ptr = '\0';
}

} // namespace hud_translit

#endif  // LIBPATCH_BLMJCIAAPA_HUD_TRANSLIT_H
