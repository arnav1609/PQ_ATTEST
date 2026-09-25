#!/usr/bin/env python3
"""
Cycle-accurate Python simulation of the WHOLE ROUTER as noc_router.sv wires it.

WHAT THIS IS
------------
A transliteration of the RTL source text of M2/M3/M4/M7/M8 into Python, run
against directed tests. It exists because no SystemVerilog simulator was
available when M7 was restructured and M8 was written, and shipping an
unexecuted rewrite to Vivado is how you burn a day on a bug that a five-minute
model would have found.

WHAT IT PROVES
--------------
  - the ALGORITHM of the two-stage allocator
  - the INTEGRATION wiring in noc_router.sv: index reshaping, sel_* derivation,
    select_* derivation, output qualification
  - end-to-end flit movement: input -> FIFO -> allocate -> crossbar -> output
  - the specific cases that motivated the rewrite (N->E, two VCs one port)

WHAT IT CANNOT PROVE
--------------------
  - anything SystemVerilog-specific: elaboration, width truncation, X
    propagation, latch inference, delta-cycle ordering, XSim quirks
  - that the RTL compiles at all

This is a MODEL OF THE RTL, not the RTL. A pass here means the design is
probably right; only xelab and xsim can say it IS right. Do not record a
result from this file in VERIFICATION_LOG.md as a simulation result.
"""

import sys

# ---- from noc_pkg -----------------------------------------------------------
MESH_X, MESH_Y = 3, 2
NUM_PORTS, NUM_VC = 5, 3
NUM_INPUT_VCS = NUM_PORTS * NUM_VC
VC0_DEPTH = VC1_DEPTH = VC2_DEPTH = 4

PORT_NORTH, PORT_SOUTH, PORT_EAST, PORT_WEST, PORT_LOCAL = range(5)
PNAME = ["NORTH", "SOUTH", "EAST", "WEST", "LOCAL"]

FLIT_HEAD, FLIT_BODY, FLIT_TAIL, FLIT_HEAD_TAIL = 0, 1, 2, 3
FNAME = ["HEAD", "BODY", "TAIL", "HEAD_TAIL"]


def input_vc_port(g):    return g // NUM_VC
def input_vc_channel(g): return g % NUM_VC
def make_input_vc(p, v): return p * NUM_VC + v


class Flit:
    __slots__ = ("data", "ftype", "vc")
    def __init__(self, data=0, ftype=FLIT_HEAD, vc=0):
        self.data, self.ftype, self.vc = data, ftype, vc
    def dest(self):
        return (self.data >> 29) & 0x7, (self.data >> 26) & 0x7
    def __repr__(self):
        dx, dy = self.dest()
        return f"<{FNAME[self.ftype]} vc{self.vc} ->({dx},{dy}) d={self.data:08x}>"


# =============================================================================
# M2 noc_fifo
# =============================================================================
class Fifo:
    def __init__(self, depth): self.depth = depth; self.q = []
    def empty(self): return len(self.q) == 0
    def full(self):  return len(self.q) >= self.depth
    def head(self):  return self.q[0] if self.q else Flit(0, FLIT_HEAD, 0)
    def step(self, wr_en, flit, rd_en):
        """Registered. Read and write in the same cycle both take effect."""
        popped = None
        if rd_en and self.q:  popped = self.q.pop(0)
        if wr_en and not self.full(): self.q.append(flit)
        return popped


# =============================================================================
# M5 noc_xy_routing
# =============================================================================
def valid_coord(x, y): return x < MESH_X and y < MESH_Y

def port_exists(cx, cy, p):
    if p == PORT_NORTH: return cy > 0
    if p == PORT_SOUTH: return (cy + 1) < MESH_Y
    if p == PORT_EAST:  return (cx + 1) < MESH_X
    if p == PORT_WEST:  return cx > 0
    if p == PORT_LOCAL: return True
    return False

def xy_route(cx, cy, dx, dy):
    ok = valid_coord(cx, cy) and valid_coord(dx, dy)
    if   dx > cx: c = PORT_EAST
    elif dx < cx: c = PORT_WEST
    elif dy > cy: c = PORT_SOUTH
    elif dy < cy: c = PORT_NORTH
    else:         c = PORT_LOCAL
    return (c, 1) if (ok and port_exists(cx, cy, c)) else (PORT_LOCAL, 0)


# =============================================================================
# M6 NOC_ARBITER  (transliterated; N is a parameter)
# =============================================================================
def arbiter(req, ptr, n):
    g = v = w = 0; nxt = ptr
    for off in range(n):
        i = ptr + off
        if i >= n: i -= n
        if (req >> i) & 1:
            g, v, w = 1 << i, 1, i
            nxt = 0 if i == n - 1 else i + 1
            break
    return g, v, w, nxt


# =============================================================================
# M7 NOC_ALLOCATOR  (two-stage, transliterated from allocator.sv)
# =============================================================================
class Allocator:
    def __init__(self):
        self.in_ptr  = [0] * NUM_PORTS
        self.out_ptr = [0] * NUM_PORTS
        self.locked  = [0] * NUM_PORTS
        self.owner   = [0] * NUM_PORTS

    def comb(self, cx, cy, head, empty):
        req = [0] * NUM_PORTS
        for i in range(NUM_INPUT_VCS):
            if empty[i]: continue
            for p in range(NUM_PORTS):
                if self.locked[p] and self.owner[p] == i:
                    req[p] |= 1 << i
            if head[i].ftype in (FLIT_HEAD, FLIT_HEAD_TAIL):
                dx, dy = head[i].dest()
                rp, rv = xy_route(cx, cy, dx, dy)
                if rv and rp < NUM_PORTS and not self.locked[rp]:
                    req[rp] |= 1 << i

        # STAGE 1
        cand_valid = [0]*NUM_PORTS; cand_vc = [0]*NUM_PORTS
        cand_out   = [0]*NUM_PORTS; in_next = [0]*NUM_PORTS
        for p in range(NUM_PORTS):
            r3 = 0
            for v in range(NUM_VC):
                g = p*NUM_VC + v
                if any((req[o] >> g) & 1 for o in range(NUM_PORTS)):
                    r3 |= 1 << v
            _, v3, w3, n3 = arbiter(r3, self.in_ptr[p], NUM_VC)
            in_next[p] = n3
            if v3:
                gvc = p*NUM_VC + w3
                cand_valid[p], cand_vc[p] = 1, gvc
                # RTL loops o downward so the LOWEST index survives.
                for o in range(NUM_PORTS-1, -1, -1):
                    if (req[o] >> gvc) & 1: cand_out[p] = o

        # STAGE 2
        out_req = [0]*NUM_PORTS
        for p in range(NUM_PORTS):
            if cand_valid[p]: out_req[cand_out[p]] |= 1 << p

        grant=[0]*NUM_PORTS; gv=0; xsel=[0]*NUM_PORTS
        owin=[0]*NUM_PORTS; onext=[0]*NUM_PORTS; rd=0
        for o in range(NUM_PORTS):
            _, v5, w5, n5 = arbiter(out_req[o], self.out_ptr[o], NUM_PORTS)
            onext[o], owin[o] = n5, w5
            if v5:
                gvc = cand_vc[w5]
                grant[o] = 1 << gvc; gv |= 1 << o
                xsel[o] = gvc; rd |= 1 << gvc
        return dict(req=req, grant=grant, gv=gv, xsel=xsel, rd=rd,
                    cand_valid=cand_valid, cand_vc=cand_vc, cand_out=cand_out,
                    owin=owin, in_next=in_next, out_next=onext)

    def commit(self, c, head, rst=False):
        if rst:
            self.in_ptr=[0]*NUM_PORTS; self.out_ptr=[0]*NUM_PORTS
            self.locked=[0]*NUM_PORTS; self.owner=[0]*NUM_PORTS; return
        for p in range(NUM_PORTS):
            if c['cand_valid'][p]: self.in_ptr[p] = c['in_next'][p]
        for o in range(NUM_PORTS):
            if (c['gv'] >> o) & 1: self.out_ptr[o] = c['out_next'][o]
        for o in range(NUM_PORTS):
            if not ((c['gv'] >> o) & 1): continue
            gvc = c['xsel'][o]; ft = head[gvc].ftype
            if ft == FLIT_HEAD:
                if not self.locked[o]:
                    self.locked[o] = 1; self.owner[o] = gvc
            elif ft == FLIT_TAIL:
                if self.locked[o] and self.owner[o] == gvc:
                    self.locked[o] = 0; self.owner[o] = 0


# =============================================================================
# M4 + M8 + M3 : the router, wired exactly as noc_router.sv does
# =============================================================================
class Router:
    def __init__(self, cx, cy):
        self.cx, self.cy = cx, cy
        depths = [VC0_DEPTH, VC1_DEPTH, VC2_DEPTH]
        self.fifo = [Fifo(depths[input_vc_channel(g)]) for g in range(NUM_INPUT_VCS)]
        self.alloc = Allocator()
        self.errors = []

    def cycle(self, in_flit, in_valid, rst=False):
        """in_flit/in_valid indexed by physical port. Returns (out_flit,out_valid)."""
        if rst:
            for f in self.fifo: f.q.clear()
            self.alloc.commit(None, None, rst=True)
            return [None]*NUM_PORTS, [0]*NUM_PORTS

        head  = [self.fifo[g].head()  for g in range(NUM_INPUT_VCS)]
        empty = [1 if self.fifo[g].empty() else 0 for g in range(NUM_INPUT_VCS)]

        c = self.alloc.comb(self.cx, self.cy, head, empty)

        # ---- M8: sel_*_vc* and select_* from the SAME grant ----------------
        sel = [[0]*NUM_VC for _ in range(NUM_PORTS)]   # sel[port][vc]
        PORT_NONE = 7
        select = [PORT_NONE]*NUM_PORTS                 # A8-b: idle != a real port
        for o in range(NUM_PORTS):
            if (c['gv'] >> o) & 1:
                p = input_vc_port(c['xsel'][o]); v = input_vc_channel(c['xsel'][o])
                select[o] = p
                sel[p][v] = 1

        # A9: a physical input may present at most one VC
        for p in range(NUM_PORTS):
            if sum(sel[p]) > 1:
                self.errors.append(f"A9 VIOLATED: {PNAME[p]} input presents "
                                   f"{sum(sel[p])} VCs (M7 regressed)")

        # ---- M4 crossbar-input mux (priority case, lowest VC wins) ---------
        xb_in  = [None]*NUM_PORTS
        xb_vin = [0]*NUM_PORTS
        for p in range(NUM_PORTS):
            for v in range(NUM_VC):
                if sel[p][v]:
                    g = make_input_vc(p, v)
                    xb_in[p]  = head[g]
                    xb_vin[p] = 0 if empty[g] else 1
                    break

        # ---- M3 crossbar : out_valid[o] = in_valid[select[o]] --------------
        xb_out = [None]*NUM_PORTS; xb_val = [0]*NUM_PORTS
        for o in range(NUM_PORTS):
            s = select[o]
            if s >= NUM_PORTS:                      # crossbar default branch
                xb_out[o] = None; xb_val[o] = 0; continue
            xb_out[o] = xb_in[s]
            xb_val[o] = xb_vin[s]
            if xb_vin[s] and s == o:
                self.errors.append(f"LOOPBACK: {PNAME[o]} in -> {PNAME[o]} out")

        # ---- M8 output qualification (contract L-07) -----------------------
        out_flit  = [None]*NUM_PORTS
        out_valid = [0]*NUM_PORTS
        for o in range(NUM_PORTS):
            out_flit[o]  = xb_out[o]
            out_valid[o] = xb_val[o] & ((c['gv'] >> o) & 1)

        # ---- dequeue exactly where granted, enqueue arrivals ---------------
        for g in range(NUM_INPUT_VCS):
            p = input_vc_port(g); v = input_vc_channel(g)
            wr = 1 if (in_valid[p] and in_flit[p] is not None
                       and in_flit[p].vc == v) else 0
            self.fifo[g].step(wr, in_flit[p] if wr else None,
                              (c['rd'] >> g) & 1)

        self.alloc.commit(c, head)
        return out_flit, out_valid, c


# =============================================================================
# DIRECTED TESTS
# =============================================================================
def mkflit(dx, dy, ft, vc, tag=0):
    return Flit((dx << 29) | (dy << 26) | (tag & 0x03FFFFFF), ft, vc)

FAIL = []
def check(cond, name, detail=""):
    if cond: print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}   {detail}"); FAIL.append(name)

def idle(): return [None]*NUM_PORTS, [0]*NUM_PORTS

def run():
    print("=" * 66)
    print(" Python cycle model of noc_router  (M4 + M7 + M3 as M8 wires them)")
    print(" NOT a SystemVerilog simulation. See module docstring.")
    print("=" * 66)

    # ---- T1  LOCAL -> EAST -------------------------------------------------
    r = Router(1, 0)
    f, v = idle(); f[PORT_LOCAL] = mkflit(2, 0, FLIT_HEAD_TAIL, 0); v[PORT_LOCAL] = 1
    r.cycle(f, v)                                   # enqueue
    of, ov, c = r.cycle(*idle())                    # allocate + traverse
    check(ov[PORT_EAST] == 1 and sum(ov) == 1, "T1  LOCAL -> EAST",
          f"out_valid={ov}")

    # ---- T2  NORTH -> EAST   (the case Bug 1 would have dropped) -----------
    r = Router(1, 0)
    f, v = idle(); f[PORT_NORTH] = mkflit(2, 0, FLIT_HEAD_TAIL, 0); v[PORT_NORTH] = 1
    r.cycle(f, v)
    of, ov, c = r.cycle(*idle())
    check(ov[PORT_EAST] == 1, "T2  NORTH -> EAST  (Bug 1 regression)",
          f"out_valid={ov}")
    check(ov[PORT_NORTH] == 0, "T2b NORTH output stays invalid", f"ov={ov}")

    # ---- T3  NORTH -> WEST -------------------------------------------------
    r = Router(1, 0)
    f, v = idle(); f[PORT_NORTH] = mkflit(0, 0, FLIT_HEAD_TAIL, 0); v[PORT_NORTH] = 1
    r.cycle(f, v); of, ov, c = r.cycle(*idle())
    check(ov[PORT_WEST] == 1 and sum(ov) == 1, "T3  NORTH -> WEST", f"ov={ov}")

    # ---- T4  SOUTH -> EAST -------------------------------------------------
    r = Router(1, 1)
    f, v = idle(); f[PORT_SOUTH] = mkflit(2, 1, FLIT_HEAD_TAIL, 0); v[PORT_SOUTH] = 1
    r.cycle(f, v); of, ov, c = r.cycle(*idle())
    check(ov[PORT_EAST] == 1 and sum(ov) == 1, "T4  SOUTH -> EAST", f"ov={ov}")

    # ---- T5  SAME PORT, TWO VCs  (the A9 case) -----------------------------
    r = Router(1, 0)
    f, v = idle(); f[PORT_NORTH] = mkflit(2, 0, FLIT_HEAD_TAIL, 0); v[PORT_NORTH] = 1
    r.cycle(f, v)                                   # NORTH VC0 -> EAST
    f, v = idle(); f[PORT_NORTH] = mkflit(0, 0, FLIT_HEAD_TAIL, 1); v[PORT_NORTH] = 1
    r.cycle(f, v)                                   # NORTH VC1 -> WEST
    of, ov, c = r.cycle(*idle())
    check(sum(ov) == 1, "T5  NORTH VC0->EAST + VC1->WEST : exactly one wins",
          f"out_valid={ov}  (>1 means the structural hazard is back)")
    check(bin(c['rd']).count('1') == 1, "T5b only one FIFO dequeued",
          f"rd={c['rd']:015b}")
    check(not r.errors, "T5c no A9 violation reported", str(r.errors[:2]))

    # ---- T6  TWO PORTS, DISJOINT OUTPUTS : both proceed --------------------
    r = Router(1, 0)
    f, v = idle()
    f[PORT_NORTH] = mkflit(2, 0, FLIT_HEAD_TAIL, 0); v[PORT_NORTH] = 1
    f[PORT_SOUTH] = mkflit(0, 0, FLIT_HEAD_TAIL, 0); v[PORT_SOUTH] = 1
    r.cycle(f, v); of, ov, c = r.cycle(*idle())
    check(ov[PORT_EAST] == 1 and ov[PORT_WEST] == 1,
          "T6  NORTH->EAST and SOUTH->WEST simultaneously", f"ov={ov}")

    # ---- T7  TWO PORTS, SAME OUTPUT : exactly one --------------------------
    r = Router(1, 0)
    f, v = idle()
    f[PORT_NORTH] = mkflit(2, 0, FLIT_HEAD_TAIL, 0); v[PORT_NORTH] = 1
    f[PORT_SOUTH] = mkflit(2, 0, FLIT_HEAD_TAIL, 0); v[PORT_SOUTH] = 1
    r.cycle(f, v); of, ov, c = r.cycle(*idle())
    check(ov[PORT_EAST] == 1 and sum(ov) == 1,
          "T7  two inputs contend for EAST : one wins", f"ov={ov}")

    # ---- T8  WORMHOLE HEAD/BODY/BODY/TAIL ----------------------------------
    r = Router(1, 0)
    seq = [(mkflit(2,0,FLIT_HEAD,0,0xA0), "HEAD"),
           (mkflit(0,0,FLIT_BODY,0,0xB1), "BODY"),   # header would say WEST
           (mkflit(0,0,FLIT_BODY,0,0xB2), "BODY"),
           (mkflit(0,0,FLIT_TAIL,0,0xC3), "TAIL")]
    outs = []
    def collect(of, ov):
        for o in range(NUM_PORTS):
            if ov[o]: outs.append((o, of[o].ftype))
    # Collect on EVERY cycle. The first version only looked after the pushes,
    # by which time three of the four flits had already been forwarded - a
    # harness bug that read as a design failure.
    for fl, _ in seq:
        f, v = idle(); f[PORT_LOCAL] = fl; v[PORT_LOCAL] = 1
        of, ov, c = r.cycle(f, v); collect(of, ov)
    for _ in range(6):
        of, ov, c = r.cycle(*idle()); collect(of, ov)
    ports = {o for o, _ in outs}
    check(ports == {PORT_EAST}, "T8  wormhole stays on EAST for all 4 flits",
          f"ports used = {[PNAME[p] for p in ports]}")
    check([t for _, t in outs] == [FLIT_HEAD, FLIT_BODY, FLIT_BODY, FLIT_TAIL],
          "T8b flit order preserved", str([FNAME[t] for _, t in outs]))
    check(r.alloc.locked[PORT_EAST] == 0, "T8c TAIL released the reservation",
          f"locked={r.alloc.locked}")

    # ---- T9  HEAD_TAIL leaves no reservation -------------------------------
    r = Router(1, 0)
    f, v = idle(); f[PORT_LOCAL] = mkflit(2, 0, FLIT_HEAD_TAIL, 0); v[PORT_LOCAL] = 1
    r.cycle(f, v); r.cycle(*idle())
    check(r.alloc.locked[PORT_EAST] == 0, "T9  HEAD_TAIL leaves no lock",
          f"locked={r.alloc.locked}")

    # ---- T10 reset ---------------------------------------------------------
    r = Router(1, 0)
    f, v = idle(); f[PORT_LOCAL] = mkflit(2, 0, FLIT_HEAD, 0); v[PORT_LOCAL] = 1
    r.cycle(f, v); r.cycle(*idle())
    r.cycle(*idle(), rst=True)
    of, ov, c = r.cycle(*idle())
    check(sum(ov) == 0 and r.alloc.locked == [0]*NUM_PORTS,
          "T10 reset clears traffic and reservations",
          f"ov={ov} locked={r.alloc.locked}")

    # ---- T11 the wormhole must not be stolen mid-packet --------------------
    r = Router(1, 0)
    f, v = idle(); f[PORT_LOCAL] = mkflit(2,0,FLIT_HEAD,0,1); v[PORT_LOCAL] = 1
    r.cycle(f, v); r.cycle(*idle())                   # HEAD takes EAST
    f, v = idle()
    f[PORT_LOCAL] = mkflit(0,0,FLIT_BODY,0,2); v[PORT_LOCAL] = 1
    f[PORT_NORTH] = mkflit(2,0,FLIT_HEAD,0,3); v[PORT_NORTH] = 1
    r.cycle(f, v)
    stolen = 0
    for _ in range(3):
        of, ov, c = r.cycle(*idle())
        if ov[PORT_EAST] and input_vc_port(c['xsel'][PORT_EAST]) != PORT_LOCAL:
            stolen += 1
    check(stolen == 0, "T11 EAST not stolen while LOCAL owns it",
          f"stolen {stolen} time(s)")

    # ---- SOAK: 20k random cycles, invariants every cycle -------------------
    import random
    rng = random.Random(7)
    r = Router(1, 0); cyc = 0; uturn_skipped = 0

    def legal_dest(cx, cy, in_port):
        """Pick a destination that does not make this flit leave by the port
        it arrived on.

        WHY THIS CONSTRAINT EXISTS (finding, 2026-09-10)
        ------------------------------------------------
        The first soak drew destinations uniformly and hit
        'LOOPBACK: EAST in -> EAST out' twice in 20,000 cycles.

        That is NOT a router bug. A flit arriving on EAST came from the east
        neighbour; XY routing at THAT router would only have sent it west, so
        its destination cannot be further east. Such a flit cannot exist in a
        correctly-routed mesh, and the stimulus was manufacturing one.

        It is however a real OPEN ITEM, recorded rather than hidden: this
        router has no defence against a MISROUTED incoming flit. noc_crossbar
        asserts the U-turn but nothing prevents it. In a mesh where one tile is
        hostile (SPOOF at (2,1)), a crafted header is exactly the kind of thing
        an attacker would try. Belongs in Phase 10/11, not here.
        """
        nonlocal uturn_skipped
        for _ in range(16):
            dx, dy = rng.randrange(MESH_X), rng.randrange(MESH_Y)
            rp, rv = xy_route(cx, cy, dx, dy)
            if not rv or rp != in_port:
                return dx, dy
            uturn_skipped += 1
        return cx, cy

    for _ in range(20000):
        f, v = idle()
        for p in range(NUM_PORTS):
            if rng.random() < 0.35:
                dx, dy = legal_dest(1, 0, p)
                f[p] = mkflit(dx, dy, rng.randrange(4), rng.randrange(NUM_VC),
                              rng.randrange(1 << 20))
                v[p] = 1
        of, ov, c = r.cycle(f, v)
        # rd_en must equal OR(grant)
        rd = 0
        for o in range(NUM_PORTS): rd |= c['grant'][o]
        if rd != c['rd']: r.errors.append("rd_en != OR(grant)")
        # out_valid implies that output's grant
        for o in range(NUM_PORTS):
            if ov[o] and not ((c['gv'] >> o) & 1):
                r.errors.append(f"out_valid[{PNAME[o]}] without grant")
        cyc += 1
    check(not r.errors, f"SOAK {cyc} random cycles, all invariants",
          f"{len(r.errors)} error(s): {r.errors[:3]}")
    print(f"        (u-turn destinations rejected by the stimulus: {uturn_skipped})")

    print("=" * 66)
    if FAIL:
        print(f" RESULT: {len(FAIL)} FAILURE(S)  -> {FAIL}")
        return 1
    print(" RESULT: all directed tests and the soak PASS")
    print(" Reminder: this is a model of the RTL, not the RTL.")
    print("=" * 66)
    return 0


if __name__ == "__main__":
    sys.exit(run())
