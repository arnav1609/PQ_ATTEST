package sha3_pkg;

    // ========================================================================
    // SHA3-256 parameters
    // ========================================================================

    localparam int RATE_BITS   = 1088;
    localparam int RATE_BYTES  = 136;
    localparam int RATE_LANES  = 17;

    localparam int CAPACITY_BITS = 512;

    localparam int DIGEST_BITS  = 256;
    localparam int DIGEST_BYTES = 32;

    // SHA3 domain-separation / padding suffix
    localparam logic [7:0] SHA3_DOMAIN = 8'h06;


    // ========================================================================
    // SHA3 controller states
    // ========================================================================

    typedef enum logic [2:0] {
        SHA3_IDLE     = 3'b000,
        SHA3_LOAD     = 3'b001,
        SHA3_ABSORB   = 3'b010,
        SHA3_PERMUTE  = 3'b011,
        SHA3_SQUEEZE  = 3'b100,
        SHA3_DONE     = 3'b101
    } sha3_state_e;


    // ========================================================================
    // Input length
    //
    // Maximum message size for one SHA3 transaction.
    //
    // This will be used by the SHA3 wrapper interface. The actual value can
    // be increased later if the system interface requires larger messages.
    // ========================================================================

    localparam int MAX_MESSAGE_BYTES = 4096;

endpackage