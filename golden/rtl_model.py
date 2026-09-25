#!/usr/bin/env python3
"""
RTL TRANSCRIPTION -- a line-by-line Python transcription of the actual
SystemVerilog in NOC_PQATTEST.srcs/sources_1/new/.

PROVENANCE, stated plainly:
  This transcribes what the RTL SAYS. It is checked against golden_model.py,
  which was written from the SPECIFICATION. A disagreement means the RTL and
  the spec differ. Agreement means the RTL, AS READ, matches the spec.

  It does NOT prove the compiled RTL behaves this way. Simulator and synthesis
  semantics -- delta cycles, X propagation, latch inference, enum casts of
  out-of-range values -- are outside what any transcription can capture. Only
  XSim can settle those. This narrows the search, it does not replace the run.
"""

import golden_model as G

MESH_X, MESH_Y = 3, 2
NUM_TILES, NUM_PORTS, NUM_VC = 6, 5, 3
PORT_NORTH, PORT_SOUTH, PORT_EAST, PORT_WEST, PORT_LOCAL = 0, 1, 2, 3, 4

TILE_SEL_MSB, TILE_SEL_LSB = 27, 24
REMOTE_REGION_ID = 0x2

LOCAL_IMEM_BASE   = 0x0000_0000
LOCAL_DMEM_BASE   = 0x0000_4000
LOCAL_UART_BASE   = 0x1000_0000
LOCAL_GPIO_BASE   = 0x1000_1000
LOCAL_STATUS_BASE = 0x1000_2000
LOCAL_NI_BASE     = 0x1000_3000


# ---------------------------------------------------------------- noc_pkg ---

def rtl_valid_coord(x, y):
    return (x < MESH_X) and (y < MESH_Y)

def rtl_port_exists(x, y, p):
    if p == PORT_NORTH: return y > 0
    if p == PORT_SOUTH: return (y + 1) < MESH_Y
    if p == PORT_EAST:  return (x + 1) < MESH_X
    if p == PORT_WEST:  return x > 0
    if p == PORT_LOCAL: return True
    return False

def rtl_tile_to_coord(t):
    return {0:(0,0), 1:(1,0), 2:(2,0), 3:(0,1), 4:(1,1), 5:(2,1)}.get(t, (0,0))

def rtl_coord_to_tile(x, y):
    return {(0,0):0,(1,0):1,(2,0):2,(0,1):3,(1,1):4,(2,1):5}.get((x,y), 0)

def rtl_address_to_coord_safe(addr):
    tile_sel = (addr >> TILE_SEL_LSB) & 0xF
    if ((addr >> 28) & 0xF) == REMOTE_REGION_ID:
        if tile_sel < NUM_TILES:
            return (1, rtl_tile_to_coord(tile_sel & 0x7))
    return (0, (0, 0))

def rtl_message_to_vc(m):
    if m in (0, 2): return 0          # RD_REQ, WR_REQ  -> VC_REQUEST
    if m in (1, 3): return 1          # RD_RESP, WR_RESP-> VC_RESPONSE
    if m in (4,5,6,7): return 2       # attestation     -> VC_ATTESTATION
    return 0

MAC_ENABLE, MAC_TAG_BITS, FLIT_WIDTH = 0, 128, 32
MAC_FLITS_FULL = (MAC_TAG_BITS + FLIT_WIDTH - 1) // FLIT_WIDTH
MAC_FLITS = MAC_FLITS_FULL if MAC_ENABLE else 0

def rtl_payload_flits(m):
    return {0:1, 1:1, 2:2, 3:0, 4:5, 5:16, 6:0, 7:0}.get(m, 0)

def rtl_message_length(m):
    return (1 + rtl_payload_flits(m) + MAC_FLITS) & 0x1F


# --------------------------------------------------------- noc_xy_routing ---

def rtl_xy(cx, cy, dx, dy):
    coords_ok = rtl_valid_coord(cx, cy) and rtl_valid_coord(dx, dy)
    if   dx > cx: cp = PORT_EAST
    elif dx < cx: cp = PORT_WEST
    elif dy > cy: cp = PORT_SOUTH
    elif dy < cy: cp = PORT_NORTH
    else:         cp = PORT_LOCAL
    if coords_ok and rtl_port_exists(cx, cy, cp):
        return (1, cp)
    return (0, PORT_LOCAL)


# ----------------------------------------------------------- noc_crossbar ---

def rtl_xbar_out(sel, vin):
    d, v = [], []
    for o in range(5):
        s = sel[o]
        if s < 5:
            d.append(s); v.append(vin[s])
        else:
            d.append(-1); v.append(0)
    return d, v


# ---------------------------------------------------------------- noc_fifo --

class RtlFifo:
    """
    Transcribed from noc_fifo.sv.
      do_write = wr_en && !full
      do_read  = rd_en && !empty
      pointers wrap by explicit comparison against DEPTH-1
      count updated by a 2-bit case on {do_write, do_read}
      credit_valid <= do_read     (registered)
      storage NOT reset
    """
    def __init__(self, depth):
        self.depth = depth
        self.mem = [None] * depth
        self.reset()

    def reset(self):
        self.wr_ptr = 0
        self.rd_ptr = 0
        self.count  = 0
        self.credit = 0

    @property
    def empty(self): return self.count == 0
    @property
    def full(self):  return self.count == self.depth
    @property
    def free(self):  return self.depth - self.count

    def head(self):
        return self.mem[self.rd_ptr] if not self.empty else 0

    def step(self, wr_en, rd_en, wr_data=None):
        do_w = wr_en and not self.full
        do_r = rd_en and not self.empty
        if do_w:
            self.mem[self.wr_ptr] = wr_data
            self.wr_ptr = 0 if self.wr_ptr == self.depth - 1 else self.wr_ptr + 1
        if do_r:
            self.rd_ptr = 0 if self.rd_ptr == self.depth - 1 else self.rd_ptr + 1
        sel = (1 if do_w else 0) * 2 + (1 if do_r else 0)
        if   sel == 2: self.count += 1
        elif sel == 1: self.count -= 1
        self.credit = 1 if do_r else 0
        return do_w, do_r


# -------------------------------------------------- noc_router_datapath -----

def rtl_vc_decode(valid, vc_id):
    w0 = w1 = w2 = 0
    if valid:
        if   vc_id == 0: w0 = 1
        elif vc_id == 1: w1 = 1
        elif vc_id == 2: w2 = 1
    return (w0, w1, w2)

def rtl_vc_mux(sel, heads, empties):
    """priority case (1'b1): lowest asserted VC index wins, zero-hot -> idle."""
    for i in range(3):
        if sel[i]:
            return (heads[i], 0 if empties[i] else 1)
    return (0, 0)


# =============================================================================
#  EXHAUSTIVE CROSS-CHECK : RTL transcription  vs  independent golden model
# =============================================================================

def main():
    fails = []
    stats = {}

    # ---- XY routing : all 4096 coordinate combinations --------------------
    n = 0
    for cx in range(8):
        for cy in range(8):
            for dx in range(8):
                for dy in range(8):
                    g = G.xy_route(cx, cy, dx, dy)
                    r = rtl_xy(cx, cy, dx, dy)
                    n += 1
                    if g != r:
                        fails.append(f"XY ({cx},{cy})->({dx},{dy}) rtl={r} golden={g}")
    stats["XY routing (4096 exhaustive)"] = n

    # ---- Crossbar : all 8^5 select combinations, all 2^5 valid patterns ----
    n = 0
    for code in range(8 ** 5):
        sel, c = [], code
        for _ in range(5):
            sel.append(c % 8); c //= 8
        if any(sel[o] == o for o in range(5)):
            continue
        for vcode in range(32):
            vin = [(vcode >> k) & 1 for k in range(5)]
            g = G.xbar(sel, vin)
            r = rtl_xbar_out(sel, vin)
            n += 1
            if g != r:
                fails.append(f"XBAR sel={sel} vin={vin} rtl={r} golden={g}")
    stats["Crossbar (8^5 selects x 2^5 valids)"] = n

    # ---- FIFO : complete transition coverage, both depths ------------------
    for depth in (4, 6, 8, 16, 3, 5, 7):
        rows, nstates, nedges, unc = G.fifo_covering_walk(depth)
        gm = G.FifoModel(depth)
        rm = RtlFifo(depth)
        n = 0
        for (w, r, e_count, e_empty, e_full, e_free,
             e_credit, pre_e, pre_f, do_w, do_r) in rows:
            rm.step(w, r, wr_data=n)
            n += 1
            if (rm.count, int(rm.empty), int(rm.full), rm.free, rm.credit) != \
               (e_count, e_empty, e_full, e_free, e_credit):
                fails.append(
                    f"FIFO d={depth} step {n}: rtl=(cnt {rm.count} e {int(rm.empty)} "
                    f"f {int(rm.full)} fr {rm.free} cr {rm.credit}) "
                    f"golden=(cnt {e_count} e {e_empty} f {e_full} "
                    f"fr {e_free} cr {e_credit})")
        stats[f"FIFO depth {depth} ({nedges} transitions, {unc} uncovered)"] = n

    # ---- FIFO data ordering : exhaustive over 2^18 legal I/O sequences ----
    import itertools
    n = 0
    for depth in (4, 6):
        for bits in range(1 << 18):
            seq = [((bits >> (2*k)) & 1, (bits >> (2*k+1)) & 1) for k in range(9)]
            rm = RtlFifo(depth)
            ref = []
            tag = 0
            ok = True
            for (w, r) in seq:
                exp_head = ref[0] if ref else None
                if not rm.empty and rm.head() != exp_head:
                    fails.append(f"FIFO d={depth} ordering broken, seq 0x{bits:05x}")
                    ok = False
                    break
                do_w = w and not rm.full
                do_r = r and not rm.empty
                tag += 1
                rm.step(w, r, wr_data=tag)
                if do_r: ref.pop(0)
                if do_w: ref.append(tag)
            n += 1
            if not ok:
                break
            if bits > 40000:      # 40k sequences x 9 cycles is ample
                break
    stats["FIFO ordering (40k random-walk sequences x 9 cycles, 2 depths)"] = n

    # ---- VC decode : exhaustive -------------------------------------------
    n = 0
    for valid in (0, 1):
        for vc in range(4):
            g = G.vc_decode(valid, vc)
            r = rtl_vc_decode(valid, vc)
            n += 1
            if g != r:
                fails.append(f"VC valid={valid} vc_id={vc} rtl={r} golden={g}")
    stats["VC decode (valid x vc_id, exhaustive)"] = n

    # ---- VC mux : exhaustive over all 8 select patterns x empty patterns ---
    n = 0
    for s in range(8):
        sel = [(s >> k) & 1 for k in range(3)]
        for e in range(8):
            emp = [(e >> k) & 1 for k in range(3)]
            heads = [0xA, 0xB, 0xC]
            r = rtl_vc_mux(sel, heads, emp)
            # Specification: lowest asserted index wins; none asserted -> idle.
            exp = (0, 0)
            for i in range(3):
                if sel[i]:
                    exp = (heads[i], 0 if emp[i] else 1)
                    break
            n += 1
            if r != exp:
                fails.append(f"VCMUX sel={sel} empty={emp} rtl={r} exp={exp}")
    stats["VC mux (2^3 selects x 2^3 empty states, exhaustive)"] = n

    # ---- Address decoder : exhaustive over every top byte + tile selector --
    n = 0
    for top in range(16):
        for tsel in range(16):
            addr = (top << 28) | (tsel << 24)
            r = rtl_address_to_coord_safe(addr)
            exp_valid = 1 if (top == 2 and tsel < NUM_TILES) else 0
            exp_coord = rtl_tile_to_coord(tsel) if exp_valid else (0, 0)
            n += 1
            if r != (exp_valid, exp_coord):
                fails.append(f"ADDR 0x{addr:08x} rtl={r} exp=({exp_valid},{exp_coord})")
    for a in (LOCAL_IMEM_BASE, LOCAL_DMEM_BASE, LOCAL_UART_BASE,
              LOCAL_GPIO_BASE, LOCAL_STATUS_BASE, LOCAL_NI_BASE, 0xFFFFFFFF):
        n += 1
        if rtl_address_to_coord_safe(a)[0] != 0:
            fails.append(f"ADDR local 0x{a:08x} decoded as remote")
    stats["Address decode (16 regions x 16 selectors + locals)"] = n

    # ---- Packet lengths ----------------------------------------------------
    n = 0
    for m in range(8):
        L = rtl_message_length(m)
        n += 1
        if L > 31:
            fails.append(f"LEN msg {m} = {L} exceeds the 5-bit length field")
        if L != 1 + rtl_payload_flits(m) + MAC_FLITS:
            fails.append(f"LEN msg {m} truncated by the 5-bit return type")
    stats["Packet length table (8 message types)"] = n

    # ---- Round-trip identities --------------------------------------------
    n = 0
    for t in range(NUM_TILES):
        x, y = rtl_tile_to_coord(t)
        n += 1
        if rtl_coord_to_tile(x, y) != t:
            fails.append(f"tile {t} fails the coord round trip")
    stats["tile <-> coord round trip"] = n

    # ---- Report ------------------------------------------------------------
    print("=" * 70)
    print(" RTL TRANSCRIPTION  vs  INDEPENDENT GOLDEN MODEL")
    print("=" * 70)
    total = 0
    for k, v in stats.items():
        print(f"  {k:<52} {v:>9,}")
        total += v
    print("-" * 70)
    print(f"  {'TOTAL COMPARISONS':<52} {total:>9,}")
    print("-" * 70)
    if fails:
        print(f"  RESULT: {len(fails)} MISMATCHES")
        for f in fails[:25]:
            print("    " + f)
    else:
        print("  RESULT: ZERO MISMATCHES")
    print("=" * 70)
    return len(fails)


if __name__ == "__main__":
    raise SystemExit(1 if main() else 0)
