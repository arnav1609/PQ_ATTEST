
// File        : noc_pkg.sv
// Project     : PQ-Attest NoC
// Description : Single source of truth for NoC parameters, types, enums,
//               packet headers, coordinates, memory map, and helper functions.
//
// Architecture:
//   - 3x2 mesh
//   - 5 router ports: NORTH, SOUTH, EAST, WEST, LOCAL
//   - 32-bit flit data
//   - 3 virtual channels
//   - Credit-based flow control
//   - XY routing
//
// REVISION: Review 01 repairs applied (see REVIEW_01_NoC_Stage1_Stage2.md)
//   L-01  port_id_t added for module ports; port_e retained as semantic enum
//   L-03  Memory map now follows BRIEF_RISCV_Lane_Complete, not the old
//         top-nibble-per-tile scheme. Tile selector moved to addr[27:24].
//   L-05  'valid' REMOVED from flit_t. Validity belongs to the transfer.
//   L-08  address_to_tile() DELETED. Only the safe decoder survives.
//   L-09  L2 authentication uses TRAILING MAC FLITS, never header bits.
//   P5    mem_resp overlay added so read responses can report bus errors.
//   P7    'parameter' changed to 'localparam' throughout.
//   P8    address_to_coord_safe() no longer uses a function output argument.
//
// IMPORTANT:
//   Forward flit and backward credit are intentionally separate.
//   Do NOT create a single bidirectional link_t struct at module boundaries.
//=============================================================================

`timescale 1ns/1ps

package noc_pkg;

    //=========================================================================
    // 1. MESH TOPOLOGY
    //=========================================================================

    localparam int unsigned MESH_X    = 3;
    localparam int unsigned MESH_Y    = 2;
    localparam int unsigned NUM_TILES = MESH_X * MESH_Y;
    localparam int unsigned NUM_PORTS = 5;


    //=========================================================================
    // 2. FLIT / VC PARAMETERS
    //=========================================================================

    localparam int unsigned FLIT_WIDTH = 32;
    localparam int unsigned NUM_VC     = 3;

    localparam int unsigned VC0_DEPTH = 4;
    localparam int unsigned VC1_DEPTH = 4;
    localparam int unsigned VC2_DEPTH = 4;

    localparam int unsigned FIFO_DEPTH = 4;

    localparam int unsigned VC_ID_WIDTH =
        (NUM_VC <= 1) ? 1 : $clog2(NUM_VC);

    localparam int unsigned PORT_ID_WIDTH =
        (NUM_PORTS <= 1) ? 1 : $clog2(NUM_PORTS);

    localparam int unsigned TILE_ID_WIDTH =
        (NUM_TILES <= 1) ? 1 : $clog2(NUM_TILES);

    localparam int unsigned COORD_WIDTH = 3;

    localparam int unsigned VC0_CNT_WIDTH = $clog2(VC0_DEPTH + 1);
    localparam int unsigned VC1_CNT_WIDTH = $clog2(VC1_DEPTH + 1);
    localparam int unsigned VC2_CNT_WIDTH = $clog2(VC2_DEPTH + 1);


    //=========================================================================
    // 3. LAYER 2 PACKET AUTHENTICATION
    //=========================================================================

    // N-8.1 sec.11.4: `define PQ_MAC_ON selects the MAC-on framing build for
    // simulation. Default (no define) is unchanged: MAC_ENABLE = 0.
`ifdef PQ_MAC_ON
    localparam bit          MAC_ENABLE   = 1'b1;
`else
    localparam bit          MAC_ENABLE   = 1'b0;
`endif
    localparam int unsigned MAC_TAG_BITS = 128;

    localparam int unsigned MAC_FLITS_FULL =
        (MAC_TAG_BITS + FLIT_WIDTH - 1) / FLIT_WIDTH;

    localparam int unsigned MAC_FLITS =
        MAC_ENABLE ? MAC_FLITS_FULL : 0;


    //=========================================================================
    // 4. CREDIT TYPE
    //=========================================================================

    typedef logic [NUM_VC-1:0] credit_t;


    //=========================================================================
    // 5. ROUTER PORT IDENTIFICATION
    //=========================================================================

    typedef logic [PORT_ID_WIDTH-1:0] port_id_t;

    localparam logic [PORT_ID_WIDTH-1:0] PORT_NONE = 3'd7;

    typedef enum logic [PORT_ID_WIDTH-1:0] {
        PORT_NORTH = 3'd0,
        PORT_SOUTH = 3'd1,
        PORT_EAST  = 3'd2,
        PORT_WEST  = 3'd3,
        PORT_LOCAL = 3'd4
    } port_e;


    //=========================================================================
    // 5b. CANONICAL INPUT-VC MAPPING
    //=========================================================================

    localparam int unsigned NUM_INPUT_VCS = NUM_PORTS * NUM_VC;

    localparam int unsigned INPUT_VC_WIDTH =
        (NUM_INPUT_VCS <= 1) ? 1 : $clog2(NUM_INPUT_VCS);

    function automatic int unsigned input_vc_port (
        input int unsigned input_vc
    );
        return input_vc / NUM_VC;
    endfunction

    function automatic int unsigned input_vc_channel (
        input int unsigned input_vc
    );
        return input_vc % NUM_VC;
    endfunction

    function automatic int unsigned make_input_vc (
        input int unsigned port,
        input int unsigned vc
    );
        return port * NUM_VC + vc;
    endfunction


    //=========================================================================
    // 6. FLIT TYPE
    //=========================================================================

    typedef enum logic [1:0] {
        FLIT_HEAD      = 2'd0,
        FLIT_BODY      = 2'd1,
        FLIT_TAIL      = 2'd2,
        FLIT_HEAD_TAIL = 2'd3
    } flit_type_e;


    //=========================================================================
    // 7. VIRTUAL CHANNEL ENUMERATION
    //=========================================================================

    typedef enum logic [VC_ID_WIDTH-1:0] {
        VC_REQUEST     = 'd0,
        VC_RESPONSE    = 'd1,
        VC_ATTESTATION = 'd2
    } vc_e;


    //=========================================================================
    // 8. MESSAGE TYPES
    //=========================================================================

    typedef enum logic [3:0] {
        MSG_MEM_RD_REQ       = 4'd0,
        MSG_MEM_RD_RESP      = 4'd1,
        MSG_MEM_WR_REQ       = 4'd2,
        MSG_MEM_WR_RESP      = 4'd3,

        MSG_ATTEST_CHALLENGE = 4'd4,
        MSG_ATTEST_RESPONSE  = 4'd5,
        MSG_ATTEST_GRANT     = 4'd6,
        MSG_ATTEST_REVOKE    = 4'd7
    } msg_type_e;


    //=========================================================================
    // 9. TILE IDENTIFICATION
    //=========================================================================

    typedef enum logic [TILE_ID_WIDTH-1:0] {
        TILE_CPU0   = 'd0,
        TILE_CPU1   = 'd1,
        TILE_MEMORY = 'd2,
        TILE_CRYPTO = 'd3,
        TILE_ROT    = 'd4,
        TILE_SPOOF  = 'd5
    } tile_id_e;


    //=========================================================================
    // 10. TILE COORDINATE
    //=========================================================================

    typedef struct packed {
        logic [COORD_WIDTH-1:0] x;
        logic [COORD_WIDTH-1:0] y;
    } coord_t;


    //=========================================================================
    // 11. PACKET HEADER
    //=========================================================================

    typedef struct packed {

        logic [COORD_WIDTH-1:0] dest_x;
        logic [COORD_WIDTH-1:0] dest_y;

        logic [COORD_WIDTH-1:0] src_x;
        logic [COORD_WIDTH-1:0] src_y;

        msg_type_e              msg_type;

        logic [4:0]             length;

        union packed {

            logic [10:0] raw;

            struct packed {
                logic [3:0]  wstrb;
                logic [6:0]  unused;
            } mem_wr;

            struct packed {
                logic        err;
                logic [9:0]  unused;
            } mem_resp;

            struct packed {
                logic [3:0]  status;
                logic [6:0]  unused;
            } attest;

        } control;

    } head_flit_t;


    //=========================================================================
    // 12. PHYSICAL FLIT
    //=========================================================================

    typedef struct packed {

        logic [FLIT_WIDTH-1:0]  flit_data;

        flit_type_e             flit_type;

        logic [VC_ID_WIDTH-1:0] vc_id;

    } flit_t;

    localparam int unsigned FLIT_STORAGE_WIDTH = $bits(flit_t);


    //=========================================================================
    // 13. MEMORY REQUEST / RESPONSE CONTRACTS
    //=========================================================================

    typedef struct packed {
        logic [31:0] addr;
        logic [31:0] wdata;
        logic [3:0]  wstrb;
        logic        we;
    } mem_req_t;

    typedef struct packed {
        logic [31:0] rdata;
        logic        err;
    } mem_resp_t;


    //=========================================================================
    // 14. ATTESTATION PARAMETERS
    //=========================================================================

    localparam int unsigned ATTEST_CHALLENGE_WIDTH = 160;
    localparam int unsigned ATTEST_RESPONSE_WIDTH  = 512;
    localparam int unsigned ATTEST_STATUS_WIDTH    = 4;


    //=========================================================================
    // 15. MEMORY MAP
    //=========================================================================

    localparam logic [31:0] LOCAL_IMEM_BASE   = 32'h0000_0000;
    localparam logic [31:0] LOCAL_DMEM_BASE   = 32'h0000_4000;
    localparam logic [31:0] LOCAL_UART_BASE   = 32'h1000_0000;
    localparam logic [31:0] LOCAL_GPIO_BASE   = 32'h1000_1000;
    localparam logic [31:0] LOCAL_STATUS_BASE = 32'h1000_2000;
    localparam logic [31:0] LOCAL_NI_BASE     = 32'h1000_3000;

    localparam logic [31:0] REMOTE_BASE       = 32'h2000_0000;
    localparam logic [3:0]  REMOTE_REGION_ID  = 4'h2;

    localparam int unsigned TILE_SEL_MSB      = 27;
    localparam int unsigned TILE_SEL_LSB      = 24;
    localparam int unsigned TILE_SEL_WIDTH    =
        TILE_SEL_MSB - TILE_SEL_LSB + 1;


    //=========================================================================
    // 15b. LOCAL REGION SIZES AND TARGET ENUMERATION
    //=========================================================================

    localparam logic [31:0] LOCAL_IMEM_SIZE   = 32'h0000_4000;
    localparam logic [31:0] LOCAL_DMEM_SIZE   = 32'h0000_4000;
    localparam logic [31:0] LOCAL_PERIPH_SIZE = 32'h0000_1000;

    typedef enum logic [2:0] {
        LOCAL_NONE   = 3'd0,
        LOCAL_IMEM   = 3'd1,
        LOCAL_DMEM   = 3'd2,
        LOCAL_UART   = 3'd3,
        LOCAL_GPIO   = 3'd4,
        LOCAL_STATUS = 3'd5,
        LOCAL_NI     = 3'd6
    } local_target_e;


    //=========================================================================
    // 15c. OUTSTANDING TRANSACTION CONFIGURATION
    //=========================================================================

    localparam int unsigned N_OUTSTANDING = 2;

    localparam int unsigned TXN_TAG_WIDTH =
        (N_OUTSTANDING <= 1) ? 1 : $clog2(N_OUTSTANDING);


    //=========================================================================
    // Transaction tag type
    //=========================================================================

    typedef logic [TXN_TAG_WIDTH-1:0] txn_tag_t;


    //=========================================================================
    // Memory-write control overlay
    //
    // control[10:7] = WSTRB
    // control[6:1]  = unused
    // control[0]    = transaction tag
    //=========================================================================

    typedef struct packed {
        logic [3:0]                   wstrb;
        logic [6-TXN_TAG_WIDTH:0]     unused;
        txn_tag_t                     tag;
    } mem_wr_control_t;


    //=========================================================================
    // Memory-response control overlay
    //
    // control[10]   = ERR
    // control[9:1]  = unused
    // control[0]    = transaction tag
    //=========================================================================

    typedef struct packed {
        logic                         err;
        logic [9-TXN_TAG_WIDTH:0]     unused;
        txn_tag_t                     tag;
    } mem_resp_control_t;


    //=========================================================================
    // Transaction tag helpers
    //=========================================================================

    function automatic txn_tag_t get_txn_tag(
        input logic [10:0] control
    );
        return control[TXN_TAG_WIDTH-1:0];
    endfunction


    function automatic logic [10:0] set_txn_tag(
        input logic [10:0] control,
        input txn_tag_t     tag
    );
        logic [10:0] result;

        result = control;
        result[TXN_TAG_WIDTH-1:0] = tag;

        return result;
    endfunction


    //=========================================================================
    // Message classification helpers
    //=========================================================================

    function automatic logic is_memory_request(
        input msg_type_e msg
    );
        case (msg)
            MSG_MEM_RD_REQ,
            MSG_MEM_WR_REQ:
                return 1'b1;

            default:
                return 1'b0;
        endcase
    endfunction


    function automatic logic is_memory_response(
        input msg_type_e msg
    );
        case (msg)
            MSG_MEM_RD_RESP,
            MSG_MEM_WR_RESP:
                return 1'b1;

            default:
                return 1'b0;
        endcase
    endfunction


    //=========================================================================
    // Request -> expected response mapping
    //=========================================================================

    function automatic msg_type_e expected_response_type(
        input msg_type_e req_msg
    );
        case (req_msg)

            MSG_MEM_RD_REQ:
                return MSG_MEM_RD_RESP;

            MSG_MEM_WR_REQ:
                return MSG_MEM_WR_RESP;

            default:
                return MSG_MEM_RD_RESP;

        endcase
    endfunction


    //=========================================================================
    // 16. ADDRESS DECODE RESULT
    //=========================================================================

    typedef struct packed {
        logic   valid;
        coord_t coord;
    } addr_decode_t;


    //=========================================================================
    // 17. TILE -> COORDINATE
    //=========================================================================

    function automatic coord_t tile_to_coord (
        input tile_id_e tile_id
    );

        coord_t coord;

        case (tile_id)

            TILE_CPU0:   begin coord.x = 3'd0; coord.y = 3'd0; end
            TILE_CPU1:   begin coord.x = 3'd1; coord.y = 3'd0; end
            TILE_MEMORY: begin coord.x = 3'd2; coord.y = 3'd0; end
            TILE_CRYPTO: begin coord.x = 3'd0; coord.y = 3'd1; end
            TILE_ROT:    begin coord.x = 3'd1; coord.y = 3'd1; end
            TILE_SPOOF:  begin coord.x = 3'd2; coord.y = 3'd1; end

            default:     begin coord.x = '0;   coord.y = '0;   end

        endcase

        return coord;

    endfunction


    //=========================================================================
    // 18. COORDINATE -> TILE
    //=========================================================================

    function automatic tile_id_e coord_to_tile (
        input coord_t coord
    );

        case ({coord.y, coord.x})

            {3'd0, 3'd0}: return TILE_CPU0;
            {3'd0, 3'd1}: return TILE_CPU1;
            {3'd0, 3'd2}: return TILE_MEMORY;

            {3'd1, 3'd0}: return TILE_CRYPTO;
            {3'd1, 3'd1}: return TILE_ROT;
            {3'd1, 3'd2}: return TILE_SPOOF;

            default:      return TILE_CPU0;

        endcase

    endfunction


    //=========================================================================
    // 19. VALID COORDINATE CHECK
    //=========================================================================

    function automatic logic valid_coord (
        input coord_t coord
    );

        return ((coord.x < MESH_X) && (coord.y < MESH_Y));

    endfunction


    //=========================================================================
    // 20. SAFE ADDRESS DECODE
    //=========================================================================

    function automatic addr_decode_t address_to_coord_safe (
        input logic [31:0] address
    );

        addr_decode_t              result;
        logic [TILE_SEL_WIDTH-1:0] tile_sel;

        result.valid = 1'b0;
        result.coord = '0;

        tile_sel = address[TILE_SEL_MSB:TILE_SEL_LSB];

        if (address[31:28] == REMOTE_REGION_ID) begin

            if (int'(tile_sel) < int'(NUM_TILES)) begin
                result.valid = 1'b1;
                result.coord =
                    tile_to_coord(
                        tile_id_e'(tile_sel[TILE_ID_WIDTH-1:0])
                    );
            end

        end

        return result;

    endfunction


    //=========================================================================
    // 21. MESSAGE TYPE -> VIRTUAL CHANNEL
    //=========================================================================

    function automatic vc_e message_to_vc (
        input msg_type_e msg_type
    );

        case (msg_type)

            MSG_MEM_RD_REQ,
            MSG_MEM_WR_REQ:
                return VC_REQUEST;

            MSG_MEM_RD_RESP,
            MSG_MEM_WR_RESP:
                return VC_RESPONSE;

            MSG_ATTEST_CHALLENGE,
            MSG_ATTEST_RESPONSE,
            MSG_ATTEST_GRANT,
            MSG_ATTEST_REVOKE:
                return VC_ATTESTATION;

            default:
                return VC_REQUEST;

        endcase

    endfunction


    //=========================================================================
    // 22. MESSAGE TYPE -> PAYLOAD FLIT COUNT
    //=========================================================================

    function automatic logic [4:0] message_payload_flits (
        input msg_type_e msg_type
    );

        case (msg_type)

            MSG_MEM_RD_REQ:       return 5'd1;
            MSG_MEM_RD_RESP:      return 5'd1;
            MSG_MEM_WR_REQ:       return 5'd2;
            MSG_MEM_WR_RESP:      return 5'd0;

            MSG_ATTEST_CHALLENGE: return 5'd5;
            MSG_ATTEST_RESPONSE:  return 5'd16;
            MSG_ATTEST_GRANT:     return 5'd0;
            MSG_ATTEST_REVOKE:    return 5'd0;

            default:              return 5'd0;

        endcase

    endfunction


    //=========================================================================
    // 23. MESSAGE TYPE -> TOTAL PACKET LENGTH
    //=========================================================================

    function automatic logic [4:0] message_length (
        input msg_type_e msg_type
    );

        return 5'd1
             + message_payload_flits(msg_type)
             + MAC_FLITS;

    endfunction


    // Worst case is the attestation response.
    localparam int unsigned MAX_PACKET_FLITS =
        1 + 16 + MAC_FLITS_FULL;


    //=========================================================================
    // 24. OPPOSITE PORT
    //=========================================================================

    function automatic port_e opposite_port (
        input port_e port
    );

        case (port)

            PORT_NORTH: return PORT_SOUTH;
            PORT_SOUTH: return PORT_NORTH;
            PORT_EAST:  return PORT_WEST;
            PORT_WEST:  return PORT_EAST;
            PORT_LOCAL: return PORT_LOCAL;

            default:    return PORT_LOCAL;

        endcase

    endfunction


    //=========================================================================
    // 25. PORT EXISTENCE
    //=========================================================================

    function automatic logic port_exists (
        input coord_t coord,
        input port_e  port
    );

        case (port)

            PORT_NORTH: return (coord.y > 0);
            PORT_SOUTH: return ((coord.y + 1) < MESH_Y);
            PORT_EAST:  return ((coord.x + 1) < MESH_X);
            PORT_WEST:  return (coord.x > 0);
            PORT_LOCAL: return 1'b1;

            default:    return 1'b0;

        endcase

    endfunction

endpackage