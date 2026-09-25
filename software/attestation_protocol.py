"""
PQ-Attest v1 — Attestation Protocol Reference
-----------------------------------------------

Models the complete attestation protocol exchange between
a tile (prover) and a verifier.

Wire format:

    Verifier -> Tile:   AttestationRequest
                        (tile_id, epoch, nonce)

    Tile -> Verifier:   AttestationResponse
                        (tile_id, epoch, nonce, measurement, tag)

The verifier recomputes the expected tag using the tile's
per-tile key and returns an explicit ACCEPT / REJECT verdict.
"""

from dataclasses import dataclass

from attestation_ref import (
    generate_attestation_tag,
    verify_attestation,
    ATTEST_TAG_BYTES,
)


# ============================================================
# Protocol Messages
# ============================================================

@dataclass
class AttestationRequest:
    """
    Verifier -> Tile challenge.

    Fields
    ------
    tile_id : bytes
        Target tile identifier.

    epoch : bytes
        Current security epoch.

    nonce : bytes
        Fresh random challenge (must not be reused).
    """

    tile_id: bytes
    epoch: bytes
    nonce: bytes


@dataclass
class AttestationResponse:
    """
    Tile -> Verifier response.

    Fields
    ------
    tile_id : bytes
        Responding tile's identifier.

    epoch : bytes
        Epoch used during measurement.

    nonce : bytes
        Echo of the verifier's challenge nonce.

    measurement : bytes
        SHA3-256 digest of (TILE_ID || CONFIG || IMEM).

    tag : bytes
        KMAC128 authentication tag over the transcript.
    """

    tile_id: bytes
    epoch: bytes
    nonce: bytes
    measurement: bytes
    tag: bytes


# ============================================================
# Verdict
# ============================================================

@dataclass
class AttestationVerdict:
    """
    Result of the verifier's check.

    accepted : bool
        True if the response is valid.

    reason : str
        Human-readable explanation.
    """

    accepted: bool
    reason: str


ACCEPT = "ACCEPT"
REJECT = "REJECT"


# ============================================================
# Tile Side
# ============================================================

def tile_respond(tile_key, request, measurement):
    """
    Tile-side: generate an attestation response.

    Parameters
    ----------
    tile_key : bytes
        Per-tile secret key (from KDF).

    request : AttestationRequest
        The verifier's challenge.

    measurement : bytes
        Current SHA3-256 measurement of this tile.

    Returns
    -------
    AttestationResponse
        Complete response ready to send to the verifier.
    """

    tag = generate_attestation_tag(
        tile_key=tile_key,
        tile_id=request.tile_id,
        epoch=request.epoch,
        nonce=request.nonce,
        measurement=measurement,
    )

    return AttestationResponse(
        tile_id=request.tile_id,
        epoch=request.epoch,
        nonce=request.nonce,
        measurement=measurement,
        tag=tag,
    )


# ============================================================
# Verifier Side
# ============================================================

def verifier_check(tile_key, request, response):
    """
    Verifier-side: validate an attestation response.

    Parameters
    ----------
    tile_key : bytes
        Per-tile secret key (verifier must hold the same key).

    request : AttestationRequest
        The original challenge that was sent to the tile.

    response : AttestationResponse
        The response received from the tile.

    Returns
    -------
    AttestationVerdict
        ACCEPT or REJECT with a reason string.
    """

    # --------------------------------------------------------
    # Field-level validation
    # --------------------------------------------------------

    if response.tile_id != request.tile_id:
        return AttestationVerdict(
            accepted=False,
            reason="tile_id mismatch",
        )

    if response.epoch != request.epoch:
        return AttestationVerdict(
            accepted=False,
            reason="epoch mismatch",
        )

    if response.nonce != request.nonce:
        return AttestationVerdict(
            accepted=False,
            reason="nonce mismatch (possible replay)",
        )

    if not isinstance(response.measurement, bytes):
        return AttestationVerdict(
            accepted=False,
            reason="measurement is not bytes",
        )

    if len(response.measurement) != 32:
        return AttestationVerdict(
            accepted=False,
            reason="measurement length is not 32 bytes",
        )

    if not isinstance(response.tag, bytes):
        return AttestationVerdict(
            accepted=False,
            reason="tag is not bytes",
        )

    if len(response.tag) != ATTEST_TAG_BYTES:
        return AttestationVerdict(
            accepted=False,
            reason="tag length mismatch",
        )

    # --------------------------------------------------------
    # Cryptographic verification
    # --------------------------------------------------------

    tag_valid = verify_attestation(
        tile_key=tile_key,
        tile_id=response.tile_id,
        epoch=response.epoch,
        nonce=response.nonce,
        measurement=response.measurement,
        received_tag=response.tag,
    )

    if not tag_valid:
        return AttestationVerdict(
            accepted=False,
            reason="KMAC128 tag verification failed",
        )

    return AttestationVerdict(
        accepted=True,
        reason="all checks passed",
    )


# ============================================================
# Self-test
# ============================================================

if __name__ == "__main__":

    from kmac128_ref import derive_tile_key
    from hashlib import sha3_256

    ROOT_SECRET = bytes.fromhex(
        "000102030405060708090a0b0c0d0e0f"
        "101112131415161718191a1b1c1d1e1f"
    )

    TILE_ID = b"TILE_01"
    EPOCH = b"EPOCH_0001"
    CONTEXT = b"PQ-ATTEST-KDF"

    NONCE = bytes.fromhex(
        "f55ba327291604f0e5be6651752398b7"
    )

    # Derive tile key
    tile_key = derive_tile_key(
        ROOT_SECRET,
        TILE_ID,
        EPOCH,
        CONTEXT,
        16,
    )

    # Calculate measurement
    measurement = sha3_256(
        TILE_ID + b"CONFIG_V1" + bytes(range(32))
    ).digest()

    # Build request
    request = AttestationRequest(
        tile_id=TILE_ID,
        epoch=EPOCH,
        nonce=NONCE,
    )

    # Tile responds
    response = tile_respond(
        tile_key,
        request,
        measurement,
    )

    # Verifier checks
    verdict = verifier_check(
        tile_key,
        request,
        response,
    )

    print("PQ-Attest Attestation Protocol Self-Test")
    print("=" * 60)

    print(f"Tile ID     : {TILE_ID.decode()}")
    print(f"Epoch       : {EPOCH.decode()}")
    print(f"Nonce       : {NONCE.hex()}")
    print(f"Measurement : {measurement.hex()}")
    print(f"Tag         : {response.tag.hex()}")
    print()
    print(f"Verdict     : {ACCEPT if verdict.accepted else REJECT}")
    print(f"Reason      : {verdict.reason}")

    if not verdict.accepted:
        raise SystemExit(1)
