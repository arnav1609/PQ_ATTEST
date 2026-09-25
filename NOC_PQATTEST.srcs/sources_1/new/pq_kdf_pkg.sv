`timescale 1ns/1ps

package pq_kdf_pkg;

    // ============================================================
    // PQ-Attest
    // Stage 5 - KDF
    // ============================================================


    // ============================================================
    // ROOT SECRET
    // ============================================================

    localparam int ROOT_SECRET_BYTES = 32;
    localparam int ROOT_SECRET_BITS  = 256;


    // ============================================================
    // TILE ID
    //
    // Reference:
    //     "TILE_01" = 7 bytes
    //     "TILE_02" = 7 bytes
    // ============================================================

    localparam int TILE_ID_BYTES = 7;
    localparam int TILE_ID_BITS  = 56;


    // ============================================================
    // EPOCH
    //
    // Reference:
    //     "EPOCH_0001" = 10 bytes
    //     "EPOCH_0002" = 10 bytes
    // ============================================================

    localparam int EPOCH_BYTES = 10;
    localparam int EPOCH_BITS  = 80;


    // ============================================================
    // CONTEXT
    //
    // Maximum reference context:
    //
    //     "PQ-ATTEST-AUTH" = 14 bytes
    //
    // Also supports empty context.
    // ============================================================

    localparam int CONTEXT_MAX_BYTES = 14;
    localparam int CONTEXT_MAX_BITS  = 112;

    localparam int CONTEXT_LEN_BITS = 4;


    // ============================================================
    // SP 800-185 ENCODED LENGTHS
    //
    // left_encode(56) = 01 38
    //     2 + 7 = 9 bytes
    //
    // left_encode(80) = 01 50
    //     2 + 10 = 12 bytes
    //
    // Maximum context:
    //
    // left_encode(112) = 01 70
    //     2 + 14 = 16 bytes
    // ============================================================

    localparam int TILE_ID_ENCODED_BYTES = 9;
    localparam int TILE_ID_ENCODED_BITS  = 72;

    localparam int EPOCH_ENCODED_BYTES = 12;
    localparam int EPOCH_ENCODED_BITS  = 96;

    localparam int CONTEXT_ENCODED_BYTES = 16;
    localparam int CONTEXT_ENCODED_BITS  = 128;


    // ============================================================
    // KDF MESSAGE
    //
    // 9 + 12 + 16 = 37 bytes maximum
    // ============================================================

    localparam int KDF_MESSAGE_MAX_BYTES = 37;
    localparam int KDF_MESSAGE_MAX_BITS  = 296;


    // ============================================================
    // KMAC128
    // ============================================================

    localparam int KMAC_RATE_BYTES = 168;
    localparam int KMAC_RATE_BITS  = 1344;


    // ============================================================
    // KDF OUTPUT
    // ============================================================

    localparam int KDF_KEY_128_BITS = 128;
    localparam int KDF_KEY_256_BITS = 256;

    localparam int KDF_KEY_MAX_BITS = 256;


    // ============================================================
    // KEY LENGTH SELECTOR
    // ============================================================

    localparam logic [1:0] KDF_LEN_128 = 2'b00;
    localparam logic [1:0] KDF_LEN_256 = 2'b01;

endpackage
