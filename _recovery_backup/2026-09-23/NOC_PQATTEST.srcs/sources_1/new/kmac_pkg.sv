`timescale 1ns/1ps

package kmac_pkg;

    // ============================================================
    // KMAC128 PARAMETERS
    // ============================================================

    // KMAC128 is based on cSHAKE128.
    //
    // Rate     = 1344 bits = 168 bytes
    // Capacity = 256 bits

    localparam int RATE_BITS     = 1344;
    localparam int RATE_BYTES    = RATE_BITS / 8;
    localparam int RATE_LANES    = RATE_BITS / 64;

    localparam int CAPACITY_BITS = 256;


    // ============================================================
    // OUTPUT
    // ============================================================

    localparam int TAG_BITS  = 256;
    localparam int TAG_BYTES = TAG_BITS / 8;


    // ============================================================
    // SP800-185 CONSTANTS
    // ============================================================

    localparam logic [7:0] KMAC_DOMAIN   = 8'h04;
    localparam logic [7:0] CSHAKE_DOMAIN = 8'h04;
    localparam logic [7:0] SHAKE_DOMAIN  = 8'h1F;


    // ============================================================
    // KMAC FUNCTION NAME
    // ============================================================

    localparam logic [31:0] KMAC_NAME = 32'h4B4D4143;

    localparam int KMAC_NAME_BYTES = 4;


    // ============================================================
    // ENCODING LIMITS
    // ============================================================

    // Architectural v1 interface limit.
    localparam int MAX_KEY_BYTES = 32;

    // Architectural v1 message limit.
    //
    // RAISED FROM 16 FOR STAGE 5. The KDF message is:
    //     encode_string(TILE_ID)  =  9      (fixed, 7-byte ID)
    //   + encode_string(EPOCH)    = 12      (fixed, 10-byte epoch)
    //   + encode_string(CONTEXT)  = 2 + context_len,  context_len 0..14
    //   = 23 .. 37 bytes
    // 40 leaves headroom and keeps the value byte-round.
    localparam int MAX_MSG_BYTES = 40;

    localparam int MAX_CUSTOM_BYTES = 16;


    // ============================================================
    // LENGTH FIELD WIDTHS
    // ============================================================

    localparam int KEY_LEN_W =
        $clog2(MAX_KEY_BYTES + 1);

    localparam int MSG_LEN_W =
        $clog2(MAX_MSG_BYTES + 1);

    localparam int CUSTOM_LEN_W =
        $clog2(MAX_CUSTOM_BYTES + 1);


    // ============================================================
    // OUTPUT LENGTH
    // ============================================================

    localparam int OUTPUT_LEN_W =
        $clog2(TAG_BYTES + 1);


    // ============================================================
    // OUTPUT LENGTH SELECTOR  (added for Stage 5)
    //
    // In KMAC, L is NOT a truncation choice. L is absorbed as
    // right_encode(L), so a different L is a different message and
    // therefore a different computation:
    //
    //     KMAC128(K, X, 128)  !=  KMAC128(K, X, 256)[0:16]
    //
    // Verified against kmac128_ref.py with the V01 KDF inputs:
    //     L=128            -> 9c699e785af03e632e2da3cbe9ede27c  (V01)
    //     L=256 truncated  -> f3d22e09c5b0ba3b0e5a7c85ab7703fc  (V06 prefix)
    //
    // right_encode(128) = 80 01        -> 2 bytes
    // right_encode(256) = 01 00 02     -> 3 bytes
    //
    // The byte COUNT differs, which is why the KMAC domain byte that
    // follows it also moves. See kmac128's final_block.
    // ============================================================

    localparam logic KMAC_L_128 = 1'b0;
    localparam logic KMAC_L_256 = 1'b1;

    localparam int RIGHT_ENC_BYTES_128 = 2;
    localparam int RIGHT_ENC_BYTES_256 = 3;


    // ============================================================
    // CONTROLLER STATES
    // ============================================================

    typedef enum logic [3:0] {

        KMAC_IDLE       = 4'b0000,
        KMAC_LOAD       = 4'b0001,
        KMAC_ENCODE     = 4'b0010,
        KMAC_ABSORB     = 4'b0011,
        KMAC_PERMUTE    = 4'b0100,
        KMAC_SQUEEZE    = 4'b0101,
        KMAC_DONE       = 4'b0110

    } kmac_state_e;

endpackage