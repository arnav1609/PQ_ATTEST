"""
PQ-Attest v1 — Runtime Attestation Reference
---------------------------------------------

Nonce-bound KMAC128 challenge-response.

Attestation tag:

    TAG = KMAC128(
        K_tile,
        TILE_ID || EPOCH || NONCE || MEASUREMENT,
        output_bytes=32,
        customization=b"PQ-ATTEST-AUTH"
    )

The nonce makes each attestation response challenge-specific
and prevents replay of an old valid response.
"""

from kmac128_ref import kmac128


# ---------------------------------------------------------------------------
# Protocol constants
# ---------------------------------------------------------------------------

ATTEST_TAG_BYTES = 32
ATTEST_CONTEXT = b"PQ-ATTEST-AUTH"


# ---------------------------------------------------------------------------
# Transcript construction
# ---------------------------------------------------------------------------

def build_attestation_message(tile_id, epoch, nonce, measurement):
    """
    Construct the authenticated attestation transcript.

    Parameters
    ----------
    tile_id : bytes
        Tile identifier.

    epoch : bytes
        Current security/measurement epoch.

    nonce : bytes
        Fresh verifier challenge.

    measurement : bytes
        SHA3-256 measurement of the tile.

    Returns
    -------
    bytes
        Transcript authenticated by KMAC128.
    """

    if not isinstance(tile_id, bytes):
        raise TypeError("tile_id must be bytes")

    if not isinstance(epoch, bytes):
        raise TypeError("epoch must be bytes")

    if not isinstance(nonce, bytes):
        raise TypeError("nonce must be bytes")

    if not isinstance(measurement, bytes):
        raise TypeError("measurement must be bytes")

    if len(nonce) == 0:
        raise ValueError("nonce must not be empty")

    if len(measurement) != 32:
        raise ValueError("measurement must be exactly 32 bytes")

    return (
        tile_id
        + epoch
        + nonce
        + measurement
    )


# ---------------------------------------------------------------------------
# Generate attestation response
# ---------------------------------------------------------------------------

def generate_attestation_tag(
    tile_key,
    tile_id,
    epoch,
    nonce,
    measurement
):
    """
    Generate a nonce-bound KMAC128 attestation tag.

    Parameters
    ----------
    tile_key : bytes
        Per-tile secret key derived from the root secret.

    tile_id : bytes
        Tile identifier.

    epoch : bytes
        Current epoch.

    nonce : bytes
        Fresh verifier challenge.

    measurement : bytes
        SHA3-256 measurement.

    Returns
    -------
    bytes
        256-bit authentication tag.
    """

    message = build_attestation_message(
        tile_id,
        epoch,
        nonce,
        measurement
    )

    return kmac128(
        key=tile_key,
        message=message,
        output_bytes=ATTEST_TAG_BYTES,
        customization=ATTEST_CONTEXT
    )


# ---------------------------------------------------------------------------
# Verify attestation response
# ---------------------------------------------------------------------------

def verify_attestation(
    tile_key,
    tile_id,
    epoch,
    nonce,
    measurement,
    received_tag
):
    """
    Verify a runtime attestation response.

    Returns True only if the received tag matches the expected
    tag for the supplied tile, epoch, nonce and measurement.
    """

    if not isinstance(received_tag, bytes):
        raise TypeError("received_tag must be bytes")

    if len(received_tag) != ATTEST_TAG_BYTES:
        return False

    expected_tag = generate_attestation_tag(
        tile_key=tile_key,
        tile_id=tile_id,
        epoch=epoch,
        nonce=nonce,
        measurement=measurement
    )

    return expected_tag == received_tag


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

if __name__ == "__main__":

    TILE_KEY = bytes.fromhex(
        "9c699e785af03e632e2da3cbe9ede27c"
    )

    TILE_ID = b"TILE_01"
    EPOCH = b"EPOCH_0001"

    NONCE = bytes.fromhex(
        "f55ba327291604f0e5be6651752398b7"
    )

    MEASUREMENT = bytes.fromhex(
        "959b61960366c705b889e2c09ffaead296e296475f32a610732ab9eac293182a"
    )

    tag = generate_attestation_tag(
        tile_key=TILE_KEY,
        tile_id=TILE_ID,
        epoch=EPOCH,
        nonce=NONCE,
        measurement=MEASUREMENT
    )

    print("Runtime Attestation Reference")
    print("=" * 60)

    print("Tile ID     :", TILE_ID.decode())
    print("Epoch       :", EPOCH.decode())
    print("Nonce       :", NONCE.hex())
    print("Measurement :", MEASUREMENT.hex())
    print("Tag         :", tag.hex())

    print()
    print("Self-verification:", verify_attestation(
        tile_key=TILE_KEY,
        tile_id=TILE_ID,
        epoch=EPOCH,
        nonce=NONCE,
        measurement=MEASUREMENT,
        received_tag=tag
    ))