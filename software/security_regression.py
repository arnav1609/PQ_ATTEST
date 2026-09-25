"""
PQ-Attest v1 — Security-Property Regression
---------------------------------------------

Exercises the attestation protocol for all critical
security properties:

    - Correctness
    - Anti-replay
    - Nonce binding
    - Measurement integrity
    - Tile isolation / cross-tile substitution
    - Epoch binding
    - Key binding
    - Tag integrity
    - Deterministic consistency
"""

from hashlib import sha3_256

from kmac128_ref import derive_tile_key
from attestation_protocol import (
    AttestationRequest,
    AttestationResponse,
    tile_respond,
    verifier_check,
)


# ============================================================
# Shared Constants
# ============================================================

ROOT_SECRET = bytes.fromhex(
    "000102030405060708090a0b0c0d0e0f"
    "101112131415161718191a1b1c1d1e1f"
)

CONTEXT = b"PQ-ATTEST-KDF"

TILE_1 = b"TILE_01"
TILE_2 = b"TILE_02"

EPOCH_1 = b"EPOCH_0001"
EPOCH_2 = b"EPOCH_0002"

NONCE_1 = bytes.fromhex(
    "f55ba327291604f0e5be6651752398b7"
)

NONCE_2 = bytes.fromhex(
    "aabbccddeeff00112233445566778899"
)


# ============================================================
# Derived Keys
# ============================================================

TILE1_KEY = derive_tile_key(
    ROOT_SECRET, TILE_1, EPOCH_1, CONTEXT, 16
)

TILE2_KEY = derive_tile_key(
    ROOT_SECRET, TILE_2, EPOCH_1, CONTEXT, 16
)


# ============================================================
# Measurements
# ============================================================

MEASUREMENT_1 = sha3_256(
    TILE_1 + b"CONFIG_01" + bytes(range(32))
).digest()

MEASUREMENT_2 = sha3_256(
    TILE_2 + b"CONFIG_02" + bytes(range(32, 64))
).digest()


# ============================================================
# Test Helper
# ============================================================

def check(name, condition):
    if condition:
        print(f"{name:<55} PASS")
        return 1
    else:
        print(f"{name:<55} FAIL")
        return 0


# ============================================================
# Main
# ============================================================

def main():

    passed = 0
    total = 0

    print("PQ-Attest v1 Security-Property Regression")
    print("=" * 70)

    # --------------------------------------------------------
    # 1. Valid attestation round-trip
    # --------------------------------------------------------

    request1 = AttestationRequest(
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_1,
    )

    response1 = tile_respond(
        TILE1_KEY,
        request1,
        MEASUREMENT_1,
    )

    verdict = verifier_check(
        TILE1_KEY,
        request1,
        response1,
    )

    passed += check(
        "1. Valid round-trip -> ACCEPT",
        verdict.accepted is True
        and verdict.reason == "all checks passed",
    )
    total += 1

    # --------------------------------------------------------
    # 2. Replay old response with original nonce
    #
    # The verifier issues a FRESH request with a NEW nonce.
    # The attacker replays the old response (which contains
    # the OLD nonce). The verifier detects the nonce mismatch.
    # --------------------------------------------------------

    fresh_request = AttestationRequest(
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_2,
    )

    verdict = verifier_check(
        TILE1_KEY,
        fresh_request,
        response1,
    )

    passed += check(
        "2. Replay old response -> REJECT (nonce mismatch)",
        verdict.accepted is False
        and "nonce" in verdict.reason,
    )
    total += 1

    # --------------------------------------------------------
    # 3. Replay old response with fresh nonce patched in
    #
    # The attacker takes the old response and replaces the
    # nonce field with the fresh one, but keeps the old tag.
    # The tag will not verify because it was computed over
    # the original nonce.
    # --------------------------------------------------------

    patched_response = AttestationResponse(
        tile_id=response1.tile_id,
        epoch=response1.epoch,
        nonce=NONCE_2,
        measurement=response1.measurement,
        tag=response1.tag,
    )

    verdict = verifier_check(
        TILE1_KEY,
        fresh_request,
        patched_response,
    )

    passed += check(
        "3. Patched nonce in old response -> REJECT (tag fail)",
        verdict.accepted is False
        and "tag" in verdict.reason.lower(),
    )
    total += 1

    # --------------------------------------------------------
    # 4. Modified measurement in response
    # --------------------------------------------------------

    tampered_measurement = bytearray(MEASUREMENT_1)
    tampered_measurement[0] ^= 0x01
    tampered_measurement = bytes(tampered_measurement)

    tampered_response = AttestationResponse(
        tile_id=response1.tile_id,
        epoch=response1.epoch,
        nonce=response1.nonce,
        measurement=tampered_measurement,
        tag=response1.tag,
    )

    verdict = verifier_check(
        TILE1_KEY,
        request1,
        tampered_response,
    )

    passed += check(
        "4. Modified measurement -> REJECT",
        verdict.accepted is False,
    )
    total += 1

    # --------------------------------------------------------
    # 5. Wrong tile (use Tile 2 key to verify Tile 1 response)
    # --------------------------------------------------------

    verdict = verifier_check(
        TILE2_KEY,
        request1,
        response1,
    )

    passed += check(
        "5. Wrong tile key -> REJECT",
        verdict.accepted is False,
    )
    total += 1

    # --------------------------------------------------------
    # 6. Wrong epoch
    #
    # Verifier issued a request for EPOCH_1, but response
    # claims EPOCH_2.
    # --------------------------------------------------------

    epoch_tampered_response = AttestationResponse(
        tile_id=response1.tile_id,
        epoch=EPOCH_2,
        nonce=response1.nonce,
        measurement=response1.measurement,
        tag=response1.tag,
    )

    verdict = verifier_check(
        TILE1_KEY,
        request1,
        epoch_tampered_response,
    )

    passed += check(
        "6. Wrong epoch -> REJECT (epoch mismatch)",
        verdict.accepted is False
        and "epoch" in verdict.reason,
    )
    total += 1

    # --------------------------------------------------------
    # 7. Wrong key (completely different root secret)
    # --------------------------------------------------------

    wrong_root = bytes.fromhex(
        "ffffffffffffffffffffffffffffffff"
        "ffffffffffffffffffffffffffffffff"
    )

    wrong_key = derive_tile_key(
        wrong_root, TILE_1, EPOCH_1, CONTEXT, 16
    )

    verdict = verifier_check(
        wrong_key,
        request1,
        response1,
    )

    passed += check(
        "7. Wrong root secret -> REJECT",
        verdict.accepted is False,
    )
    total += 1

    # --------------------------------------------------------
    # 8. Fresh nonce produces different tag
    # --------------------------------------------------------

    request_nonce2 = AttestationRequest(
        tile_id=TILE_1,
        epoch=EPOCH_1,
        nonce=NONCE_2,
    )

    response_nonce2 = tile_respond(
        TILE1_KEY,
        request_nonce2,
        MEASUREMENT_1,
    )

    passed += check(
        "8. Fresh nonce -> different tag",
        response_nonce2.tag != response1.tag,
    )
    total += 1

    # --------------------------------------------------------
    # 9. Cross-tile substitution
    #
    # Attacker takes Tile 2's valid response and presents
    # it as if it came from Tile 1.
    # --------------------------------------------------------

    request2 = AttestationRequest(
        tile_id=TILE_2,
        epoch=EPOCH_1,
        nonce=NONCE_1,
    )

    response2 = tile_respond(
        TILE2_KEY,
        request2,
        MEASUREMENT_2,
    )

    # Swap tile_id to Tile 1
    cross_tile_response = AttestationResponse(
        tile_id=TILE_1,
        epoch=response2.epoch,
        nonce=response2.nonce,
        measurement=response2.measurement,
        tag=response2.tag,
    )

    verdict = verifier_check(
        TILE1_KEY,
        request1,
        cross_tile_response,
    )

    passed += check(
        "9. Cross-tile substitution -> REJECT",
        verdict.accepted is False,
    )
    total += 1

    # --------------------------------------------------------
    # 10. Tampered tag
    # --------------------------------------------------------

    tampered_tag = bytearray(response1.tag)
    tampered_tag[-1] ^= 0xFF
    tampered_tag = bytes(tampered_tag)

    tag_tampered_response = AttestationResponse(
        tile_id=response1.tile_id,
        epoch=response1.epoch,
        nonce=response1.nonce,
        measurement=response1.measurement,
        tag=tampered_tag,
    )

    verdict = verifier_check(
        TILE1_KEY,
        request1,
        tag_tampered_response,
    )

    passed += check(
        "10. Tampered tag -> REJECT",
        verdict.accepted is False,
    )
    total += 1

    # --------------------------------------------------------
    # 11. Deterministic: same inputs -> same verdict
    # --------------------------------------------------------

    response1_again = tile_respond(
        TILE1_KEY,
        request1,
        MEASUREMENT_1,
    )

    verdict_again = verifier_check(
        TILE1_KEY,
        request1,
        response1_again,
    )

    passed += check(
        "11. Deterministic -> same ACCEPT",
        verdict_again.accepted is True
        and response1_again.tag == response1.tag,
    )
    total += 1

    # --------------------------------------------------------
    # Summary
    # --------------------------------------------------------

    failed = total - passed

    print("=" * 70)
    print(f"PASSED : {passed} / {total}")
    print(f"FAILED : {failed} / {total}")

    if passed == total:
        print("\nSECURITY-PROPERTY REGRESSION PASSED")
    else:
        print("\nSECURITY-PROPERTY REGRESSION FAILED")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
