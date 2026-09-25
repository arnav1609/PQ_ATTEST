`timescale 1ns/1ps

package trng_pkg;

    // ============================================================
    // Raw entropy
    // ============================================================

    localparam int RAW_ENTROPY_BITS  = 4096;
    localparam int RAW_ENTROPY_BYTES = RAW_ENTROPY_BITS / 8;
    localparam int RAW_ENTROPY_WORDS = RAW_ENTROPY_BITS / 64;


    // ============================================================
    // Keccak rate
    //
    // 1088 bits = 136 bytes = 17 x 64-bit words
    // ============================================================

    localparam int KECCAK_RATE_BITS  = 1088;
    localparam int KECCAK_RATE_BYTES = KECCAK_RATE_BITS / 8;
    localparam int KECCAK_RATE_WORDS = KECCAK_RATE_BITS / 64;


    // ============================================================
    // Padding
    //
    // 4096 raw bits = 64 words
    // + 4 padding words
    // = 68 total words
    //
    // 68 / 17 = 4 Keccak blocks
    // ============================================================

    localparam int PADDING_WORDS = 4;

    localparam int TOTAL_WORDS =
        RAW_ENTROPY_WORDS + PADDING_WORDS;

    localparam int NUM_BLOCKS =
        TOTAL_WORDS / KECCAK_RATE_WORDS;


    // ============================================================
    // Conditioned output
    // ============================================================

    localparam int CONDITIONED_BITS  = 256;
    localparam int CONDITIONED_BYTES = CONDITIONED_BITS / 8;


    // ============================================================
    // Nonce
    // ============================================================

    localparam int NONCE_BITS  = 128;
    localparam int NONCE_BYTES = NONCE_BITS / 8;


    // ============================================================
    // Default online health-test threshold
    // ============================================================

    localparam int DEFAULT_MAX_REPETITIONS = 32;

endpackage