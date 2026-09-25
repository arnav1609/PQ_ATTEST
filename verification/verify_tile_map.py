"""
PQ-Attest P1-2 Tile Map Verifier
================================

Parses the authoritative NOC_PKG.sv and verifies that:

    TILE_ID enum
        matches
    tile_to_coord() mapping

No tile_map.json.
No hardcoded authoritative tile map.

The RTL package is the source of truth.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


# ============================================================================
# Data structures
# ============================================================================

@dataclass(frozen=True)
class Tile:
    name: str
    tile_id: int
    x: int
    y: int


@dataclass
class VerificationResult:
    passed: bool
    issues: list[str]


# ============================================================================
# Parsing helpers
# ============================================================================

TILE_ENUM_RE = re.compile(
    r"""
    typedef\s+enum\s+logic\s*
    \[[^\]]+\]
    \s*\{
        (?P<body>.*?)
    \}\s*tile_id_e\s*;
    """,
    re.DOTALL | re.VERBOSE,
)

TILE_ENUM_ENTRY_RE = re.compile(
    r"""
    (?P<name>TILE_[A-Z0-9_]+)
    \s*=\s*'d(?P<id>\d+)
    """,
    re.VERBOSE,
)

TILE_COORD_FUNCTION_RE = re.compile(
    r"""
    function\s+automatic\s+coord_t\s+tile_to_coord
    \s*\(
        .*?
    \)
    .*?
    case\s*\(\s*tile_id\s*\)
    (?P<body>.*?)
    endcase
    .*?
    endfunction
    """,
    re.DOTALL | re.VERBOSE,
)

TILE_COORD_ENTRY_RE = re.compile(
    r"""
    (?P<name>TILE_[A-Z0-9_]+)
    \s*:
    \s*begin
        \s*coord\.x\s*=\s*3'd(?P<x>\d+)
        \s*;
        \s*coord\.y\s*=\s*3'd(?P<y>\d+)
        \s*;
    \s*end
    """,
    re.DOTALL | re.VERBOSE,
)


# ============================================================================
# Parser
# ============================================================================

def parse_tile_enum(text: str) -> dict[str, int]:
    match = TILE_ENUM_RE.search(text)

    if not match:
        raise ValueError(
            "Could not find typedef enum tile_id_e"
        )

    body = match.group("body")

    entries = {}

    for entry in TILE_ENUM_ENTRY_RE.finditer(body):
        name = entry.group("name")
        tile_id = int(entry.group("id"))

        if name in entries:
            raise ValueError(
                f"Duplicate tile enum name: {name}"
            )

        entries[name] = tile_id

    if not entries:
        raise ValueError(
            "tile_id_e contains no tile entries"
        )

    return entries


def parse_tile_coordinates(text: str) -> dict[str, tuple[int, int]]:
    match = TILE_COORD_FUNCTION_RE.search(text)

    if not match:
        raise ValueError(
            "Could not find tile_to_coord() function"
        )

    body = match.group("body")

    entries = {}

    for entry in TILE_COORD_ENTRY_RE.finditer(body):
        name = entry.group("name")
        x = int(entry.group("x"))
        y = int(entry.group("y"))

        if name in entries:
            raise ValueError(
                f"Duplicate coordinate mapping: {name}"
            )

        entries[name] = (x, y)

    if not entries:
        raise ValueError(
            "tile_to_coord() contains no coordinate mappings"
        )

    return entries


# ============================================================================
# Verification
# ============================================================================

def verify_tile_map(
    tile_enum: dict[str, int],
    coordinates: dict[str, tuple[int, int]],
    mesh_x: int,
    mesh_y: int,
) -> VerificationResult:

    issues: list[str] = []

    enum_names = set(tile_enum)
    coord_names = set(coordinates)

    # ------------------------------------------------------------------------
    # Every enum tile must have a coordinate
    # ------------------------------------------------------------------------

    for name in sorted(enum_names - coord_names):
        issues.append(
            f"MISSING_COORDINATE: {name}"
        )

    # ------------------------------------------------------------------------
    # Every coordinate mapping must refer to an enum tile
    # ------------------------------------------------------------------------

    for name in sorted(coord_names - enum_names):
        issues.append(
            f"UNKNOWN_TILE_COORDINATE: {name}"
        )

    # ------------------------------------------------------------------------
    # Tile ID uniqueness
    # ------------------------------------------------------------------------

    id_to_names: dict[int, list[str]] = {}

    for name, tile_id in tile_enum.items():
        id_to_names.setdefault(tile_id, []).append(name)

    for tile_id, names in sorted(id_to_names.items()):
        if len(names) > 1:
            issues.append(
                f"DUPLICATE_TILE_ID: {tile_id} -> {', '.join(names)}"
            )

    # ------------------------------------------------------------------------
    # Coordinate uniqueness
    # ------------------------------------------------------------------------

    coord_to_names: dict[tuple[int, int], list[str]] = {}

    for name, coord in coordinates.items():
        coord_to_names.setdefault(coord, []).append(name)

    for coord, names in sorted(coord_to_names.items()):
        if len(names) > 1:
            issues.append(
                "DUPLICATE_COORDINATE: "
                f"{coord} -> {', '.join(names)}"
            )

    # ------------------------------------------------------------------------
    # Coordinate bounds
    # ------------------------------------------------------------------------

    for name, (x, y) in coordinates.items():

        if not (0 <= x < mesh_x):
            issues.append(
                f"INVALID_X: {name} has x={x}, "
                f"expected 0 <= x < {mesh_x}"
            )

        if not (0 <= y < mesh_y):
            issues.append(
                f"INVALID_Y: {name} has y={y}, "
                f"expected 0 <= y < {mesh_y}"
            )

    # ------------------------------------------------------------------------
    # Expected tile count from mesh dimensions
    # ------------------------------------------------------------------------

    expected_tile_count = mesh_x * mesh_y

    if len(tile_enum) != expected_tile_count:
        issues.append(
            f"TILE_COUNT_MISMATCH: found {len(tile_enum)}, "
            f"expected {expected_tile_count}"
        )

    if len(coordinates) != expected_tile_count:
        issues.append(
            f"COORDINATE_COUNT_MISMATCH: found {len(coordinates)}, "
            f"expected {expected_tile_count}"
        )

    # ------------------------------------------------------------------------
    # Tile IDs should cover 0..N-1
    # ------------------------------------------------------------------------

    expected_ids = set(range(expected_tile_count))
    actual_ids = set(tile_enum.values())

    missing_ids = expected_ids - actual_ids
    extra_ids = actual_ids - expected_ids

    for tile_id in sorted(missing_ids):
        issues.append(
            f"MISSING_TILE_ID: {tile_id}"
        )

    for tile_id in sorted(extra_ids):
        issues.append(
            f"UNEXPECTED_TILE_ID: {tile_id}"
        )

    return VerificationResult(
        passed=len(issues) == 0,
        issues=issues,
    )


# ============================================================================
# Report
# ============================================================================

def print_report(
    source: Path,
    tile_enum: dict[str, int],
    coordinates: dict[str, tuple[int, int]],
    result: VerificationResult,
) -> None:

    print()
    print("=" * 68)
    print("PQ-ATTEST P1-2 TILE MAP VERIFICATION")
    print("=" * 68)

    print(f"SOURCE              : {source}")
    print(f"TILES PARSED        : {len(tile_enum)}")
    print(f"COORDINATES PARSED  : {len(coordinates)}")
    print(
        f"STATUS              : "
        f"{'PASS' if result.passed else 'FAIL'}"
    )

    print()
    print("TILE MAP:")

    for name, tile_id in sorted(
        tile_enum.items(),
        key=lambda item: item[1],
    ):
        coord = coordinates.get(name)

        if coord is None:
            print(
                f"  {name:<16} ID={tile_id:<2} COORD=MISSING"
            )
        else:
            x, y = coord
            print(
                f"  {name:<16} ID={tile_id:<2} "
                f"COORD=({x},{y})"
            )

    if result.issues:
        print()
        print("ISSUES:")

        for issue in result.issues:
            print(f"  - {issue}")

    print("=" * 68)


# ============================================================================
# CLI
# ============================================================================

def main() -> int:

    parser = argparse.ArgumentParser(
        description=(
            "Verify PQ-Attest tile IDs and coordinates "
            "from the authoritative NOC_PKG.sv."
        )
    )

    parser.add_argument(
        "--source",
        required=True,
        help="Path to authoritative NOC_PKG.sv",
    )

    parser.add_argument(
        "--mesh-x",
        type=int,
        default=3,
        help="Expected mesh X dimension",
    )

    parser.add_argument(
        "--mesh-y",
        type=int,
        default=2,
        help="Expected mesh Y dimension",
    )

    args = parser.parse_args()

    source = Path(args.source)

    if not source.exists():
        print(
            f"ERROR: source file not found: {source}",
            file=sys.stderr,
        )
        return 2

    try:
        text = source.read_text(
            encoding="utf-8",
        )

        tile_enum = parse_tile_enum(text)
        coordinates = parse_tile_coordinates(text)

    except (OSError, UnicodeDecodeError, ValueError) as exc:
        print(
            f"PARSE ERROR: {exc}",
            file=sys.stderr,
        )
        return 2

    result = verify_tile_map(
        tile_enum,
        coordinates,
        args.mesh_x,
        args.mesh_y,
    )

    print_report(
        source,
        tile_enum,
        coordinates,
        result,
    )

    return 0 if result.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())