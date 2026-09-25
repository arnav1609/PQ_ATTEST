
// M11:
//   CPU address -> LOCAL / REMOTE / BUS ERROR
//
// Purely combinational.
// No clock, reset, FSM, buffering, handshake, or packet generation.
//
// LOCAL:
//   0x0000_0000 + 16 KB  -> IMEM
//   0x0000_4000 + 16 KB  -> DMEM
//   0x1000_0000 +  4 KB  -> UART
//   0x1000_1000 +  4 KB  -> GPIO
//   0x1000_2000 +  4 KB  -> STATUS
//   0x1000_3000 +  4 KB  -> NI
//
// REMOTE:
//   0x2T00_0000
//   T = address[27:24]
//   Legal T = 0..5
//
// ERROR:
//   Anything unmapped.
//   Self-addressed remote access is also an error by default.
//
//=============================================================================

`timescale 1ns/1ps

module noc_addr_decoder #(
    parameter int LOCAL_TILE_ID = 0,

    parameter logic [31:0] IMEM_SIZE =
        noc_pkg::LOCAL_IMEM_SIZE,

    parameter logic [31:0] DMEM_SIZE =
        noc_pkg::LOCAL_DMEM_SIZE,

    parameter logic [31:0] PERIPH_SIZE =
        noc_pkg::LOCAL_PERIPH_SIZE,

    parameter bit SELF_REMOTE_IS_ERROR = 1'b1
) (
    input  logic [31:0] addr,
    input logic        addr_valid,

    output logic                    is_local,
    output noc_pkg::local_target_e local_sel,
    output noc_pkg::addr_decode_t  remote,
    output logic                    bus_error
);

    import noc_pkg::*;

    //-------------------------------------------------------------------------
    // Current tile
    //-------------------------------------------------------------------------

    localparam tile_id_e LOCAL_TILE =
        tile_id_e'(LOCAL_TILE_ID[TILE_ID_WIDTH-1:0]);

    //-------------------------------------------------------------------------
    // Region limits
    //
    // Upper bound is EXCLUSIVE.
    //-------------------------------------------------------------------------

    localparam logic [31:0] IMEM_LIMIT =
        LOCAL_IMEM_BASE + IMEM_SIZE;

    localparam logic [31:0] DMEM_LIMIT =
        LOCAL_DMEM_BASE + DMEM_SIZE;

    localparam logic [31:0] UART_LIMIT =
        LOCAL_UART_BASE + PERIPH_SIZE;

    localparam logic [31:0] GPIO_LIMIT =
        LOCAL_GPIO_BASE + PERIPH_SIZE;

    localparam logic [31:0] STATUS_LIMIT =
        LOCAL_STATUS_BASE + PERIPH_SIZE;

    localparam logic [31:0] NI_LIMIT =
        LOCAL_NI_BASE + PERIPH_SIZE;

    //-------------------------------------------------------------------------
    // Remote decode from the package.
    //
    // Do NOT duplicate TILE_SEL decoding here.
    // noc_pkg::address_to_coord_safe() is the single source of truth.
    //-------------------------------------------------------------------------

    addr_decode_t remote_raw;

    assign remote_raw = address_to_coord_safe(addr);

    //-------------------------------------------------------------------------
    // Detect remote access targeting this tile.
    //-------------------------------------------------------------------------

    logic remote_is_self;

    assign remote_is_self =
        remote_raw.valid &&
        (remote_raw.coord == tile_to_coord(LOCAL_TILE));

    //-------------------------------------------------------------------------
    // Main decoder
    //-------------------------------------------------------------------------

    always_comb begin

        // Safe defaults
        is_local  = 1'b0;
        local_sel = LOCAL_NONE;
        remote    = '0;
        bus_error = 1'b0;

        if (addr_valid) begin

            //-----------------------------------------------------------------
            // LOCAL IMEM
            //-----------------------------------------------------------------

            if ((addr >= LOCAL_IMEM_BASE) &&
                (addr <  IMEM_LIMIT)) begin

                is_local  = 1'b1;
                local_sel = LOCAL_IMEM;
            end

            //-----------------------------------------------------------------
            // LOCAL DMEM
            //-----------------------------------------------------------------

            else if ((addr >= LOCAL_DMEM_BASE) &&
                     (addr <  DMEM_LIMIT)) begin

                is_local  = 1'b1;
                local_sel = LOCAL_DMEM;
            end

            //-----------------------------------------------------------------
            // LOCAL UART
            //-----------------------------------------------------------------

            else if ((addr >= LOCAL_UART_BASE) &&
                     (addr <  UART_LIMIT)) begin

                is_local  = 1'b1;
                local_sel = LOCAL_UART;
            end

            //-----------------------------------------------------------------
            // LOCAL GPIO
            //-----------------------------------------------------------------

            else if ((addr >= LOCAL_GPIO_BASE) &&
                     (addr <  GPIO_LIMIT)) begin

                is_local  = 1'b1;
                local_sel = LOCAL_GPIO;
            end

            //-----------------------------------------------------------------
            // LOCAL STATUS
            //-----------------------------------------------------------------

            else if ((addr >= LOCAL_STATUS_BASE) &&
                     (addr <  STATUS_LIMIT)) begin

                is_local  = 1'b1;
                local_sel = LOCAL_STATUS;
            end

            //-----------------------------------------------------------------
            // LOCAL NETWORK INTERFACE
            //-----------------------------------------------------------------

            else if ((addr >= LOCAL_NI_BASE) &&
                     (addr <  NI_LIMIT)) begin

                is_local  = 1'b1;
                local_sel = LOCAL_NI;
            end

            //-----------------------------------------------------------------
            // REMOTE
            //-----------------------------------------------------------------

            else if (remote_raw.valid &&
                     !(SELF_REMOTE_IS_ERROR && remote_is_self)) begin

                is_local  = 1'b0;
                local_sel = LOCAL_NONE;
                remote    = remote_raw;
                bus_error = 1'b0;
            end

            //-----------------------------------------------------------------
            // BUS ERROR
            //-----------------------------------------------------------------

            else begin

                is_local  = 1'b0;
                local_sel = LOCAL_NONE;
                remote    = '0;
                bus_error = 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Simulation-time structural checks
    //
    // synthesis translate_off
    //-------------------------------------------------------------------------

    initial begin

        if (IMEM_SIZE == 0)
            $fatal(1,
                "M11: IMEM_SIZE cannot be zero");

        if (DMEM_SIZE == 0)
            $fatal(1,
                "M11: DMEM_SIZE cannot be zero");

        if (PERIPH_SIZE == 0)
            $fatal(1,
                "M11: PERIPH_SIZE cannot be zero");

        if (IMEM_LIMIT > LOCAL_DMEM_BASE)
            $fatal(1,
                "M11: IMEM overlaps DMEM");

        if (DMEM_LIMIT > LOCAL_UART_BASE)
            $fatal(1,
                "M11: DMEM overlaps peripheral region");

        if (UART_LIMIT > LOCAL_GPIO_BASE)
            $fatal(1,
                "M11: UART overlaps GPIO");

        if (GPIO_LIMIT > LOCAL_STATUS_BASE)
            $fatal(1,
                "M11: GPIO overlaps STATUS");

        if (STATUS_LIMIT > LOCAL_NI_BASE)
            $fatal(1,
                "M11: STATUS overlaps NI");

        if (NI_LIMIT > REMOTE_BASE)
            $fatal(1,
                "M11: NI overlaps remote region");

        if (LOCAL_TILE_ID < 0 || LOCAL_TILE_ID >= NUM_TILES)
            $fatal(1,
                "M11: LOCAL_TILE_ID=%0d is invalid",
                LOCAL_TILE_ID);
    end

    // synthesis translate_on

endmodule