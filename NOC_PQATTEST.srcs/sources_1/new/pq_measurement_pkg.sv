`timescale 1ns/1ps
//=============================================================================
// File    : pq_measurement_pkg.sv
// Package : pq_measurement_pkg     PQ-Attest Stage 6 constants
//
// Same role pq_kdf_pkg plays for Stage 5: the module takes its widths from
// here, NOT from a parameter port list. Vivado does not accept a package
// import together with #(...) in a module header, and every working module
// in this project (sha3_256, pq_kdf, kmac128, keccak_f1600) follows the
// package pattern. Stage 6 follows it too.
//
// Names are chosen NOT to collide with sha3_pkg, which is imported alongside
// this package (sha3_pkg owns RATE_BITS / RATE_BYTES / DIGEST_BITS /
// MAX_MESSAGE_BYTES).
//=============================================================================

package pq_measurement_pkg;

    // ------------------------------------------------------------
    // TILE_ID - fixed 7 bytes, matching Stage 5 and the reference
    // vectors ("TILE_01", "TILE_02").
    // ------------------------------------------------------------
    localparam int TILE_ID_BYTES = 7;
    localparam int TILE_ID_BITS  = 56;

    // ------------------------------------------------------------
    // CONFIG - variable length, 0 .. 64 bytes.
    // Reference vectors use 0, 16 and 64.
    // ------------------------------------------------------------
    localparam int CONFIG_MAX_BYTES = 64;
    localparam int CONFIG_MAX_BITS  = 512;
    localparam int CONFIG_LEN_BITS  = 7;          // $clog2(64+1)

    // ------------------------------------------------------------
    // IMEM - variable length, 0 .. 64 bytes.
    // Reference vectors use 0, 16 and 64.
    // ------------------------------------------------------------
    localparam int IMEM_MAX_BYTES = 64;
    localparam int IMEM_MAX_BITS  = 512;
    localparam int IMEM_LEN_BITS  = 7;            // $clog2(64+1)

    // ------------------------------------------------------------
    // Measurement message: TILE_ID || CONFIG || IMEM
    //
    // 7 + 64 + 64 = 135 bytes maximum, which is exactly
    // sha3_pkg::RATE_BYTES - 1.
    //
    // THE CAP IS NOT ARBITRARY. sha3_pad only pads when
    // valid_bytes < RATE_BYTES, so a FULL 136-byte final block gets
    // no padding at all and produces a silently wrong digest.
    // Staying one byte under the rate makes that unreachable.
    // ------------------------------------------------------------
    localparam int MEASURE_MSG_MAX_BYTES = 135;

    // ------------------------------------------------------------
    // Output - must equal sha3_pkg::DIGEST_BITS.
    // Checked at elaboration in pq_measurement.sv.
    // ------------------------------------------------------------
    localparam int MEASUREMENT_BITS = 256;

endpackage