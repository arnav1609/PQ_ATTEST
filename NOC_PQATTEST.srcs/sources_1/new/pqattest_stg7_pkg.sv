//=============================================================================
// PQ-Attest  -  Stage 7  -  Attestation Authentication Tag
//
//   TAG = KMAC128( K = tile_key,
//                  X = TILE_ID || EPOCH || NONCE || MEASUREMENT,
//                  S = "PQ-ATTEST-AUTH",
//                  L )
//
// WHY A PACKAGE, AND WHY NO PARAMETER PORT LIST
//   Every field here is a fixed-width protocol constant, so there is nothing
//   for a caller to override. pq_kdf.sv uses exactly this shape: package
//   imports in the header, no #(). That pattern is proven in this repo.
//   (kmac_128.sv:3-11 proves a wildcard import CAN coexist with #(), so the
//   restriction is narrower than once recorded - Stage 7 simply has no
//   parameter worth exposing.)
//
// NAME COLLISIONS - CHECKED, NOT ASSUMED
//   pq_attestation_tag wildcard-imports BOTH this package and kmac_pkg.
//   All 22 localparams and 7 enum labels in kmac_pkg.sv were diffed against
//   the names below: zero overlap. kmac_pkg already exports TAG_BITS and
//   TAG_BYTES, which is why the output width here is TAG_MAX_BITS.
//
// BYTE ORDER
//   Project convention, uniform across the crypto lane:  byte i at [i*8 +: 8].
//   So byte 0 of a field sits at the LSB end of its vector.
//
// Target : xc7a100tcsg324-1, Vivado 2024.1
//=============================================================================

`timescale 1ns/1ps

package pq_attest_pkg;

    //-------------------------------------------------------------------------
    // TRANSCRIPT FIELDS
    //
    // Widths taken from the modules that actually produce these values:
    //   TILE_ID      pq_kdf_pkg::TILE_ID_BITS             = 56
    //   EPOCH        pq_kdf_pkg::EPOCH_BITS               = 80
    //   NONCE        TRNG_PKG::NONCE_BITS                 = 128
    //                (TRNG_TOP.sv:22  output logic [127:0] nonce_out)
    //   MEASUREMENT  pq_measurement_pkg::MEASUREMENT_BITS = 256
    //
    // Redeclared here rather than imported so that a wildcard import of this
    // package cannot collide with pq_kdf_pkg or pq_measurement_pkg, which
    // export the same identifiers. If any of those four widths changes, this
    // file must change with it - that is the cost of the choice.
    //-------------------------------------------------------------------------
    localparam int TILE_ID_BYTES     = 7;
    localparam int TILE_ID_BITS      = 56;

    localparam int EPOCH_BYTES       = 10;
    localparam int EPOCH_BITS        = 80;

    localparam int NONCE_BYTES       = 16;
    localparam int NONCE_BITS        = 128;

    localparam int MEASUREMENT_BYTES = 32;
    localparam int MEASUREMENT_BITS  = 256;

    //-------------------------------------------------------------------------
    // TRANSCRIPT LAYOUT
    //
    // All four fields are FIXED width, so the concatenation is unambiguous and
    // needs no SP 800-185 encode_string() length prefixes. This is the one
    // place Stage 7 legitimately differs from Stage 5: pq_kdf's CONTEXT is
    // variable length, so pq_kdf MUST length-prefix. Stage 7 must NOT.
    //
    //   byte  0 .. 6    TILE_ID
    //   byte  7 .. 16   EPOCH
    //   byte 17 .. 32   NONCE
    //   byte 33 .. 64   MEASUREMENT
    //   total           65 bytes
    //-------------------------------------------------------------------------
    localparam int TILE_OFF  = 0;
    localparam int EPOCH_OFF = TILE_OFF  + TILE_ID_BYTES;      //  7
    localparam int NONCE_OFF = EPOCH_OFF + EPOCH_BYTES;        // 17
    localparam int MEAS_OFF  = NONCE_OFF + NONCE_BYTES;        // 33

    localparam int TAG_MSG_BYTES = TILE_ID_BYTES + EPOCH_BYTES
                                 + NONCE_BYTES   + MEASUREMENT_BYTES;   // 65
    localparam int TAG_MSG_BITS  = TAG_MSG_BYTES * 8;                   // 520

    //-------------------------------------------------------------------------
    // TAG_MSG_BYTES = 65 IS NOT ARBITRARY. DO NOT ROUND IT TO 64 OR 63.
    //
    // (1) kmac128 absorbs exactly three rate blocks (KMAC_BLOCK0/1/2, no loop).
    //     Block 2 must hold  X || right_encode(L) || 0x04 || pad  in 168 bytes,
    //     so X <= 164.  65 + 3 + 1 = 69. Fine.
    //
    // (2) kmac_encode.sv:437-446 writes block_data[msg_len_reg + 2].
    //     msg_len_reg is $clog2(MSG_BYTES+1) bits wide and THE ADDITION IS
    //     DONE IN THAT WIDTH. If MSG_BYTES+1 is an exact power of two the
    //     index wraps and silently corrupts the message - MSG_BYTES=63 gives
    //     6 bits, and 63+2 = 65 wraps to 1. No error, wrong tag.
    //
    //     65 -> $clog2(66) = 7 bits -> max 127 -> 65+3 = 68 is safe.
    //-------------------------------------------------------------------------
    localparam int TAG_MSG_LEN_W = $clog2(TAG_MSG_BYTES + 1);           // 7

    //-------------------------------------------------------------------------
    // TILE KEY
    //
    // Fixed at 32 bytes. kmac_encode.sv:349 branches on (key_len*8 < 256);
    // a 32-byte key always takes the left_encode(256) = 02 01 00 path. The
    // other branch has never been exercised by kmac_tb, so a shorter tile key
    // is NOT supported until that branch has a KAT.
    //-------------------------------------------------------------------------
    localparam int TILE_KEY_BYTES = 32;
    localparam int TILE_KEY_BITS  = 256;
    localparam int TILE_KEY_LEN_W = $clog2(TILE_KEY_BYTES + 1);         // 6

    //-------------------------------------------------------------------------
    // CUSTOMIZATION STRING  S = "PQ-ATTEST-AUTH"
    //
    //   'P' 'Q' '-' 'A' 'T' 'T' 'E' 'S' 'T' '-' 'A' 'U' 'T' 'H'
    //    50  51  2d  41  54  54  45  53  54  2d  41  55  54  48   (byte 0 first)
    //
    // Written MSB-first below, so byte 0 ('P' = 0x50) lands at bits [7:0].
    // FULL 112-BIT LITERAL ON ONE LINE, ON PURPOSE: a short 'h literal in a
    // wide field zero-extends silently and the tag is wrong with no error.
    //
    // This is the ONLY cryptographic difference between Stage 5 and Stage 7.
    // pq_kdf passes an EMPTY customization and carries context in the message;
    // Stage 7 does the opposite. Get this wrong and the KMAC core still works
    // perfectly while domain separation is silently gone.
    //
    // 14 bytes = 112 bits. kmac_encode block 0 writes a single left_encode
    // byte (block_data[9] = custom_len*8), valid only while S_bits <= 255,
    // i.e. S <= 31 bytes. 112 is well inside that.
    //-------------------------------------------------------------------------
    localparam int AUTH_CUSTOM_BYTES = 14;
    localparam int AUTH_CUSTOM_BITS  = 112;

    localparam logic [AUTH_CUSTOM_BITS-1:0] AUTH_CUSTOM =
        112'h485455412d5453455454412d5150;

    // kmac128's CUSTOM_BYTES parameter. Left at its default 16 so the field is
    // wider than the string; bytes 14 and 15 are zero padding and are NOT
    // absorbed, because custom_len bounds the encoder's copy loop.
    localparam int KMAC_CUSTOM_BYTES = 16;
    localparam int KMAC_CUSTOM_LEN_W = $clog2(KMAC_CUSTOM_BYTES + 1);   // 5

    //-------------------------------------------------------------------------
    // OUTPUT
    //
    // tag is always 256 bits wide. For L=128 only tag[127:0] is the answer,
    // and it is the answer because right_encode(128) was ABSORBED - not
    // because a 256-bit result was truncated:
    //
    //     KMAC128(K,X,128) != KMAC128(K,X,256)[0:16]
    //
    // Confirmed on the Stage 7 inputs with a reference model that reproduces
    // all three published NIST SP 800-185 KMAC128 sample vectors:
    //     L=128            -> dabd282cc70b742effb22ca5188d393d
    //     L=256 truncated  -> 491c8ce777d0bf3577aa4fe87ec587dd
    //-------------------------------------------------------------------------
    localparam int TAG_MAX_BITS  = 256;
    localparam int TAG_128_BYTES = 16;
    localparam int TAG_256_BYTES = 32;

    //-------------------------------------------------------------------------
    // TAG LENGTH SELECTOR
    //
    // Only these two encodings are legal. 2'b10 and 2'b11 are REJECTED by
    // pq_attestation_tag, not silently coerced to 128-bit. Malformed control
    // must never select a valid cryptographic mode by accident.
    //-------------------------------------------------------------------------
    localparam logic [1:0] TAG_LEN_128 = 2'b00;
    localparam logic [1:0] TAG_LEN_256 = 2'b01;

endpackage