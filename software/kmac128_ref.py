#!/usr/bin/env python3
"""
PQ-Attest crypto-lane reference model  -  Keccak-f[1600] / FIPS 202 / SP 800-185.

Pure Python, no third-party dependencies. This is the GOLDEN MODEL: RTL is
correct only when it reproduces these functions byte-for-byte.

Self-test (run this file directly) checks, in order:
  1. Keccak-f[1600] on the all-zero state  -> FIPS 202 published lane value.
  2. SHA3-256("") and ("abc")              -> FIPS 202 KATs (via Python hashlib).
  3. KMAC128 against all THREE published NIST SP 800-185 sample vectors.
If any check fails the module raises SystemExit(1) and must not be used.

Byte order here is the NATURAL / printed order: byte 0 is first. The RTL packs
byte i at [i*8 +: 8] (byte 0 at the LSB end), so consumers that compare against
RTL literals must byte-reverse. gen_stage7_vectors.py does exactly that.
"""

# ---------------------------------------------------------------------------
# Keccak-f[1600]
# ---------------------------------------------------------------------------

_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]
_MASK = (1 << 64) - 1


def _rotl(x, n):
    n &= 63
    if n == 0:
        return x & _MASK
    return ((x << n) | (x >> (64 - n))) & _MASK


def keccak_f1600(state):
    """state: list of 25 64-bit lanes, A[x][y] = state[x + 5*y]. In place."""
    for rnd in range(24):
        # theta
        C = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
             for x in range(5)]
        D = [C[(x + 4) % 5] ^ _rotl(C[(x + 1) % 5], 1) for x in range(5)]
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] ^= D[x]
        # rho + pi
        B = [0] * 25
        for x in range(5):
            for y in range(5):
                B[y + 5 * ((2 * x + 3 * y) % 5)] = _rotl(state[x + 5 * y], _ROT[x][y])
        # chi
        for x in range(5):
            for y in range(5):
                state[x + 5 * y] = B[x + 5 * y] ^ ((~B[(x + 1) % 5 + 5 * y]) & B[(x + 2) % 5 + 5 * y])
        # iota
        state[0] ^= _RC[rnd]
    return state


# ---------------------------------------------------------------------------
# Sponge  (rate in BYTES; domain-suffix byte per FIPS 202 / SP 800-185)
# ---------------------------------------------------------------------------

def _keccak_sponge(rate, data, dsbyte, outlen):
    lanes = 25
    state = [0] * lanes
    # absorb
    off = 0
    n = len(data)
    while n - off >= rate:
        _absorb_block(state, data[off:off + rate], rate)
        keccak_f1600(state)
        off += rate
    # pad: remaining || dsbyte || 0* || 0x80 at last rate byte
    block = bytearray(data[off:]) + bytearray(rate - (n - off))
    block[n - off] ^= dsbyte
    block[rate - 1] ^= 0x80
    _absorb_block(state, bytes(block), rate)
    keccak_f1600(state)
    # squeeze
    out = bytearray()
    while len(out) < outlen:
        for i in range(rate // 8):
            out += state[i].to_bytes(8, "little")
            if len(out) >= rate:
                break
        if len(out) < outlen:
            keccak_f1600(state)
    return bytes(out[:outlen])


def _absorb_block(state, block, rate):
    for i in range(rate // 8):
        state[i] ^= int.from_bytes(block[8 * i:8 * i + 8], "little")


# ---------------------------------------------------------------------------
# SP 800-185 encodings
# ---------------------------------------------------------------------------

def left_encode(x):
    if x == 0:
        return bytes([1, 0])
    b = bytearray()
    v = x
    while v > 0:
        b.insert(0, v & 0xFF)
        v >>= 8
    return bytes([len(b)]) + bytes(b)


def right_encode(x):
    if x == 0:
        return bytes([0, 1])
    b = bytearray()
    v = x
    while v > 0:
        b.insert(0, v & 0xFF)
        v >>= 8
    return bytes(b) + bytes([len(b)])


def encode_string(s):
    return left_encode(8 * len(s)) + s


def bytepad(x, w):
    z = left_encode(w) + x
    if len(z) % w != 0:
        z += bytes(w - (len(z) % w))
    return z


# ---------------------------------------------------------------------------
# cSHAKE128 / KMAC128   (rate 168 bytes, capacity 256)
# ---------------------------------------------------------------------------

_RATE_128 = 168


def shake128(x, outlen):
    return _keccak_sponge(_RATE_128, x, 0x1F, outlen)


def cshake128(x, outlen, n=b"", s=b""):
    if n == b"" and s == b"":
        return shake128(x, outlen)
    prefix = bytepad(encode_string(n) + encode_string(s), _RATE_128)
    return _keccak_sponge(_RATE_128, prefix + x, 0x04, outlen)


def kmac128(key, message, output_bytes, customization=b""):
    newx = bytepad(encode_string(key), _RATE_128) + message + right_encode(output_bytes * 8)
    return cshake128(newx, output_bytes, n=b"KMAC", s=customization)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def _selftest():
    import hashlib
    ok = True

    # 1. Keccak-f[1600] on all-zero: A[0][0] low 8 bytes (LE) = f1258f7940e1dde7
    st = [0] * 25
    keccak_f1600(st)
    got = st[0].to_bytes(8, "little").hex()
    # FIPS 202: A[0][0] = 0xF1258F7940E1DDE7 after f1600(0); little-endian bytes:
    exp = "e7dde140798f25f1"
    print(f"  keccak_f1600(0) A[0][0] LE bytes = {got}  {'OK' if got==exp else 'FAIL'}")
    ok &= (got == exp)

    # 2. SHA3-256 KATs via our sponge (dsbyte 0x06, rate 136) vs hashlib
    def sha3_256(m):
        return _keccak_sponge(136, m, 0x06, 32)
    for msg in (b"", b"abc", b"a" * 135, b"a" * 136, b"a" * 137):
        g = sha3_256(msg).hex()
        h = hashlib.sha3_256(msg).hexdigest()
        r = (g == h)
        ok &= r
        print(f"  sha3_256(len={len(msg):3}) {'OK' if r else 'FAIL got '+g+' exp '+h}")

    # 3. NIST SP 800-185 KMAC128 sample vectors (Key = 0x40..0x5F, 32 bytes)
    K = bytes(range(0x40, 0x60))
    samples = [
        # (X, L_bits, S, expected)
        (bytes([0x00, 0x01, 0x02, 0x03]), 256, b"",
         "E5780B0D3EA6F7D3A429C5706AA43A00FADBD7D49628839E3187243F456EE14E"),
        (bytes([0x00, 0x01, 0x02, 0x03]), 256, b"My Tagged Application",
         "3B1FBA963CD8B0B59E8C1A6D71888B7143651AF8BA0A7070C0979E2811324AA5"),
        (bytes(range(200)), 256, b"My Tagged Application",
         "1F5B4E6CCA02209E0DCB5CA635B89A15E271ECC760071DFD805FAA38F9729230"),
    ]
    for i, (X, L, S, exp) in enumerate(samples, 1):
        g = kmac128(K, X, L // 8, S).hex().upper()
        r = (g == exp)
        ok &= r
        print(f"  KMAC128 NIST sample {i} : {'OK' if r else 'FAIL'}")
        if not r:
            print(f"      got {g}\n      exp {exp}")

    if not ok:
        raise SystemExit("kmac128_ref self-test FAILED")
    print("kmac128_ref self-test PASSED")


if __name__ == "__main__":
    _selftest()
