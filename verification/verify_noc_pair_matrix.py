from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from verify_tile_map import parse_tile_coordinates, parse_tile_enum
from xy_route_oracle import Coord, Direction, route


DEFAULT_MATRIX = Path("software/noc_pair_matrix.json")

DEFAULT_SOURCE = Path(
    "NOC_PQATTEST.srcs/sources_1/new/NOC_PKG.sv"
)

EXPECTED_MESH_X = 3
EXPECTED_MESH_Y = 2

VALID_DIRECTIONS = {
    direction.value
    for direction in Direction
}


class MatrixVerificationError(Exception):
    """Raised when the NoC pair matrix is invalid."""


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)

    except FileNotFoundError as exc:
        raise MatrixVerificationError(
            f"Matrix file not found: {path}"
        ) from exc

    except json.JSONDecodeError as exc:
        raise MatrixVerificationError(
            f"Invalid JSON in matrix file: {exc}"
        ) from exc

    if not isinstance(data, dict):
        raise MatrixVerificationError(
            "Matrix root must be a JSON object."
        )

    return data


def load_authoritative_tile_map(
    source_path: Path,
) -> dict[str, dict[str, Any]]:
    """
    Parse the authoritative tile enum and tile coordinates
    directly from NOC_PKG.sv.
    """

    try:
        text = source_path.read_text(encoding="utf-8")

    except FileNotFoundError as exc:
        raise MatrixVerificationError(
            f"Authoritative NOC_PKG.sv not found: {source_path}"
        ) from exc

    try:
        tile_enum = parse_tile_enum(text)
        tile_coords = parse_tile_coordinates(text)

    except Exception as exc:
        raise MatrixVerificationError(
            f"Failed to parse authoritative NOC_PKG.sv: {exc}"
        ) from exc

    if not tile_enum:
        raise MatrixVerificationError(
            "No tile enum entries parsed."
        )

    if not tile_coords:
        raise MatrixVerificationError(
            "No tile coordinates parsed."
        )

    if len(tile_enum) != len(tile_coords):
        raise MatrixVerificationError(
            "Tile enum count and coordinate count do not match."
        )

    # ------------------------------------------------------------
    # Validate tile IDs
    # ------------------------------------------------------------

    ids = list(tile_enum.values())

    if len(ids) != len(set(ids)):
        raise MatrixVerificationError(
            "Authoritative tile map contains duplicate tile IDs."
        )

    expected_ids = set(range(len(tile_enum)))

    if set(ids) != expected_ids:
        raise MatrixVerificationError(
            f"Tile IDs must be contiguous 0..{len(tile_enum) - 1}."
        )

    # ------------------------------------------------------------
    # Validate coordinates
    #
    # parse_tile_coordinates() returns (x, y) tuples.
    # ------------------------------------------------------------

    coords = list(tile_coords.values())

    if len(coords) != len(set(coords)):
        raise MatrixVerificationError(
            "Authoritative tile map contains duplicate coordinates."
        )

    for name, coord in tile_coords.items():

        if not isinstance(coord, tuple) or len(coord) != 2:
            raise MatrixVerificationError(
                f"Invalid coordinate for tile {name}: {coord}"
            )

        x, y = coord

        if not isinstance(x, int) or not isinstance(y, int):
            raise MatrixVerificationError(
                f"Non-integer coordinate for tile {name}: {coord}"
            )

        if not (0 <= x < EXPECTED_MESH_X):
            raise MatrixVerificationError(
                f"Tile {name} has out-of-bounds X coordinate: {x}"
            )

        if not (0 <= y < EXPECTED_MESH_Y):
            raise MatrixVerificationError(
                f"Tile {name} has out-of-bounds Y coordinate: {y}"
            )

        if name not in tile_enum:
            raise MatrixVerificationError(
                f"Coordinate exists without tile enum entry: {name}"
            )

    # ------------------------------------------------------------
    # Normalize into Coord objects
    # ------------------------------------------------------------

    result: dict[str, dict[str, Any]] = {}

    for name, tile_id in tile_enum.items():

        if name not in tile_coords:
            raise MatrixVerificationError(
                f"Missing coordinate for tile: {name}"
            )

        x, y = tile_coords[name]

        result[name] = {
            "id": tile_id,
            "coord": Coord(x, y),
        }

    return result


def require_field(
    obj: dict[str, Any],
    field: str,
    expected_type: type | tuple[type, ...] | None = None,
) -> Any:

    if field not in obj:
        raise MatrixVerificationError(
            f"Missing required field: {field}"
        )

    value = obj[field]

    if expected_type is not None:
        if not isinstance(value, expected_type):
            raise MatrixVerificationError(
                f"Field '{field}' has invalid type."
            )

    return value


def validate_pair(
    pair: Any,
    authoritative_tiles: dict[str, dict[str, Any]],
    pair_index: int,
) -> tuple[str, str]:

    if not isinstance(pair, dict):
        raise MatrixVerificationError(
            f"Pair {pair_index} must be a JSON object."
        )

    # ------------------------------------------------------------
    # Source / destination
    # ------------------------------------------------------------

    source = require_field(
        pair,
        "source",
        str,
    )

    destination = require_field(
        pair,
        "destination",
        str,
    )

    if source not in authoritative_tiles:
        raise MatrixVerificationError(
            f"Pair {pair_index}: unknown source tile "
            f"'{source}'."
        )

    if destination not in authoritative_tiles:
        raise MatrixVerificationError(
            f"Pair {pair_index}: unknown destination tile "
            f"'{destination}'."
        )

    # ------------------------------------------------------------
    # IDs
    # ------------------------------------------------------------

    source_id = require_field(
        pair,
        "source_id",
        int,
    )

    destination_id = require_field(
        pair,
        "destination_id",
        int,
    )

    expected_source_id = authoritative_tiles[source]["id"]
    expected_destination_id = authoritative_tiles[destination]["id"]

    if source_id != expected_source_id:
        raise MatrixVerificationError(
            f"Pair {pair_index}: wrong source_id for "
            f"{source}: got {source_id}, "
            f"expected {expected_source_id}."
        )

    if destination_id != expected_destination_id:
        raise MatrixVerificationError(
            f"Pair {pair_index}: wrong destination_id for "
            f"{destination}: got {destination_id}, "
            f"expected {expected_destination_id}."
        )

    # ------------------------------------------------------------
    # Coordinates
    # ------------------------------------------------------------

    source_coord = require_field(
        pair,
        "source_coord",
        dict,
    )

    destination_coord = require_field(
        pair,
        "destination_coord",
        dict,
    )

    expected_source_coord = authoritative_tiles[source]["coord"]

    expected_destination_coord = (
        authoritative_tiles[destination]["coord"]
    )

    actual_source_coord = Coord(
        require_field(source_coord, "x", int),
        require_field(source_coord, "y", int),
    )

    actual_destination_coord = Coord(
        require_field(destination_coord, "x", int),
        require_field(destination_coord, "y", int),
    )

    if actual_source_coord != expected_source_coord:
        raise MatrixVerificationError(
            f"Pair {pair_index}: wrong source coordinate "
            f"for {source}: "
            f"got ({actual_source_coord.x},"
            f"{actual_source_coord.y}), "
            f"expected ({expected_source_coord.x},"
            f"{expected_source_coord.y})."
        )

    if actual_destination_coord != expected_destination_coord:
        raise MatrixVerificationError(
            f"Pair {pair_index}: wrong destination coordinate "
            f"for {destination}: "
            f"got ({actual_destination_coord.x},"
            f"{actual_destination_coord.y}), "
            f"expected ({expected_destination_coord.x},"
            f"{expected_destination_coord.y})."
        )

    # ------------------------------------------------------------
    # Route
    # ------------------------------------------------------------

    actual_route = require_field(
        pair,
        "route",
        list,
    )

    invalid_directions = [
        direction
        for direction in actual_route
        if direction not in VALID_DIRECTIONS
    ]

    if invalid_directions:
        raise MatrixVerificationError(
            f"Pair {pair_index}: invalid route direction(s): "
            f"{invalid_directions}"
        )

    expected_route = route(
        expected_source_coord,
        expected_destination_coord,
    )

    expected_route_values = [
        direction.value
        for direction in expected_route
    ]

    if actual_route != expected_route_values:
        raise MatrixVerificationError(
            f"Pair {pair_index}: wrong route for "
            f"{source} -> {destination}: "
            f"got {actual_route}, "
            f"expected {expected_route_values}."
        )

    # ------------------------------------------------------------
    # Hop count
    #
    # LOCAL is represented as one route entry but has zero hops.
    # ------------------------------------------------------------

    hop_count = require_field(
        pair,
        "hop_count",
        int,
    )

    if expected_source_coord == expected_destination_coord:

        expected_hop_count = 0

        if actual_route != ["LOCAL"]:
            raise MatrixVerificationError(
                f"Pair {pair_index}: local pair must have "
                f"route ['LOCAL']."
            )

    else:

        expected_hop_count = len(expected_route_values)

        if "LOCAL" in actual_route:
            raise MatrixVerificationError(
                f"Pair {pair_index}: non-local route "
                f"contains LOCAL."
            )

    if hop_count != expected_hop_count:
        raise MatrixVerificationError(
            f"Pair {pair_index}: wrong hop_count: "
            f"got {hop_count}, "
            f"expected {expected_hop_count}."
        )

    return source, destination


def verify_matrix(
    matrix_path: Path,
    source_path: Path,
) -> dict[str, Any]:

    data = load_json(matrix_path)

    authoritative_tiles = load_authoritative_tile_map(
        source_path
    )

    # ------------------------------------------------------------
    # Top-level schema
    # ------------------------------------------------------------

    mesh = require_field(
        data,
        "mesh",
        dict,
    )

    mesh_x = require_field(
        mesh,
        "x",
        int,
    )

    mesh_y = require_field(
        mesh,
        "y",
        int,
    )

    tile_count = require_field(
        data,
        "tile_count",
        int,
    )

    pair_count = require_field(
        data,
        "pair_count",
        int,
    )

    routing = require_field(
        data,
        "routing",
        str,
    )

    pairs = require_field(
        data,
        "pairs",
        list,
    )

    # ------------------------------------------------------------
    # Mesh
    # ------------------------------------------------------------

    if mesh_x != EXPECTED_MESH_X:
        raise MatrixVerificationError(
            f"Invalid mesh.x: got {mesh_x}, "
            f"expected {EXPECTED_MESH_X}."
        )

    if mesh_y != EXPECTED_MESH_Y:
        raise MatrixVerificationError(
            f"Invalid mesh.y: got {mesh_y}, "
            f"expected {EXPECTED_MESH_Y}."
        )

    # ------------------------------------------------------------
    # Tile count
    # ------------------------------------------------------------

    expected_tile_count = len(authoritative_tiles)

    if tile_count != expected_tile_count:
        raise MatrixVerificationError(
            f"Invalid tile_count: got {tile_count}, "
            f"expected {expected_tile_count}."
        )

    # ------------------------------------------------------------
    # Routing
    # ------------------------------------------------------------

    if routing != "XY":
        raise MatrixVerificationError(
            f"Unsupported routing mode: {routing}"
        )

    # ------------------------------------------------------------
    # Pair count
    # ------------------------------------------------------------

    expected_pair_count = expected_tile_count ** 2

    if pair_count != expected_pair_count:
        raise MatrixVerificationError(
            f"Invalid pair_count: got {pair_count}, "
            f"expected {expected_pair_count}."
        )

    if len(pairs) != expected_pair_count:
        raise MatrixVerificationError(
            f"Actual pair list length is {len(pairs)}, "
            f"expected {expected_pair_count}."
        )

    # ------------------------------------------------------------
    # Validate every pair
    # ------------------------------------------------------------

    seen_pairs: set[tuple[str, str]] = set()

    for index, pair in enumerate(pairs):

        source, destination = validate_pair(
            pair,
            authoritative_tiles,
            index,
        )

        pair_key = (
            source,
            destination,
        )

        if pair_key in seen_pairs:
            raise MatrixVerificationError(
                f"Duplicate pair detected: "
                f"{source} -> {destination}"
            )

        seen_pairs.add(pair_key)

    # ------------------------------------------------------------
    # Verify complete Cartesian product
    # ------------------------------------------------------------

    expected_pairs = {
        (source, destination)
        for source in authoritative_tiles
        for destination in authoritative_tiles
    }

    missing_pairs = expected_pairs - seen_pairs

    extra_pairs = seen_pairs - expected_pairs

    if missing_pairs:

        formatted = ", ".join(
            f"{source}->{destination}"
            for source, destination in sorted(
                missing_pairs
            )
        )

        raise MatrixVerificationError(
            f"Missing pair(s): {formatted}"
        )

    if extra_pairs:

        formatted = ", ".join(
            f"{source}->{destination}"
            for source, destination in sorted(
                extra_pairs
            )
        )

        raise MatrixVerificationError(
            f"Unexpected pair(s): {formatted}"
        )

    return {
        "tiles": expected_tile_count,
        "pairs": len(pairs),
        "routing": routing,
    }


def main() -> int:

    parser = argparse.ArgumentParser(
        description=(
            "Verify generated NoC pair matrix against "
            "NOC_PKG.sv and the XY routing oracle."
        )
    )

    parser.add_argument(
        "--matrix",
        type=Path,
        default=DEFAULT_MATRIX,
        help="Generated NoC pair matrix JSON.",
    )

    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE,
        help="Authoritative NOC_PKG.sv.",
    )

    args = parser.parse_args()

    try:

        result = verify_matrix(
            matrix_path=args.matrix,
            source_path=args.source,
        )

    except MatrixVerificationError as exc:

        print(
            "PQ-ATTEST P2-1 NoC PAIR MATRIX VERIFICATION"
        )
        print(
            f"MATRIX              : {args.matrix}"
        )
        print(
            f"AUTHORITATIVE SOURCE: {args.source}"
        )
        print("STATUS              : FAIL")
        print(f"ERROR               : {exc}")

        return 1

    except Exception as exc:

        print(
            "PQ-ATTEST P2-1 NoC PAIR MATRIX VERIFICATION"
        )
        print("STATUS              : ERROR")
        print(f"ERROR               : {exc}")

        return 2

    print(
        "PQ-ATTEST P2-1 NoC PAIR MATRIX VERIFICATION"
    )
    print(
        f"MATRIX              : {args.matrix}"
    )
    print(
        f"AUTHORITATIVE SOURCE: {args.source}"
    )
    print(
        f"TILES               : {result['tiles']}"
    )
    print(
        f"PAIRS               : {result['pairs']}"
    )
    print(
        f"ROUTING             : {result['routing']}"
    )
    print("STATUS              : PASS")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())