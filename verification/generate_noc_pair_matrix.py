import json
import sys
from pathlib import Path

# Allow imports from verification/
sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_tile_map import parse_tile_enum, parse_tile_coordinates
from xy_route_oracle import Coord, Direction, route


ROOT = Path(__file__).resolve().parents[1]

SOURCE = (
    ROOT
    / "NOC_PQATTEST.srcs"
    / "sources_1"
    / "new"
    / "NOC_PKG.sv"
)

OUTPUT = ROOT / "software" / "noc_pair_matrix.json"

MESH_X = 3
MESH_Y = 2


def load_authoritative_tile_map():
    """
    Read the tile enum and tile_to_coord() directly from NOC_PKG.sv.

    NOC_PKG.sv remains the single source of truth.

    This function also enforces the structural invariants required
    before a routing matrix can be generated.
    """

    text = SOURCE.read_text(encoding="utf-8")

    tiles = parse_tile_enum(text)
    coordinates = parse_tile_coordinates(text)

    expected_count = MESH_X * MESH_Y

    # ------------------------------------------------------------------
    # Tile-count validation
    # ------------------------------------------------------------------

    if len(tiles) != expected_count:
        raise RuntimeError(
            f"Expected {expected_count} tiles, parsed {len(tiles)}"
        )

    if len(coordinates) != len(tiles):
        raise RuntimeError(
            f"Tile/coordinate count mismatch: "
            f"{len(tiles)} tiles vs {len(coordinates)} coordinates"
        )

    # ------------------------------------------------------------------
    # Tile ID validation
    # ------------------------------------------------------------------

    tile_ids = list(tiles.values())

    if len(set(tile_ids)) != len(tile_ids):
        raise RuntimeError(
            "Duplicate tile ID detected"
        )

    expected_ids = set(range(expected_count))

    if set(tile_ids) != expected_ids:
        raise RuntimeError(
            f"Tile IDs must cover 0..{expected_count - 1}; "
            f"parsed IDs: {sorted(tile_ids)}"
        )

    # ------------------------------------------------------------------
    # Coordinate validation
    # ------------------------------------------------------------------

    coordinate_values = list(coordinates.values())

    if len(set(coordinate_values)) != len(coordinate_values):
        raise RuntimeError(
            "Duplicate tile coordinate detected"
        )

    for tile_name, (x, y) in coordinates.items():

        if not (0 <= x < MESH_X):
            raise RuntimeError(
                f"Tile {tile_name} has out-of-bounds x coordinate: {x}"
            )

        if not (0 <= y < MESH_Y):
            raise RuntimeError(
                f"Tile {tile_name} has out-of-bounds y coordinate: {y}"
            )

    # ------------------------------------------------------------------
    # Every tile must have a coordinate
    # ------------------------------------------------------------------

    for tile_name in tiles:

        if tile_name not in coordinates:
            raise RuntimeError(
                f"Missing coordinate for {tile_name}"
            )

    # ------------------------------------------------------------------
    # Every coordinate must refer to a known tile
    # ------------------------------------------------------------------

    for tile_name in coordinates:

        if tile_name not in tiles:
            raise RuntimeError(
                f"Coordinate exists for unknown tile {tile_name}"
            )

    # ------------------------------------------------------------------
    # Build normalized tile representation
    # ------------------------------------------------------------------

    tile_map = []

    for tile_name, tile_id in tiles.items():

        x, y = coordinates[tile_name]

        tile_map.append(
            {
                "name": tile_name,
                "tile_id": tile_id,
                "x": x,
                "y": y,
            }
        )

    tile_map.sort(
        key=lambda tile: tile["tile_id"]
    )

    return tile_map

def generate_matrix(tiles):
    pairs = []

    for source_tile in tiles:
        source_coord = Coord(
            source_tile["x"],
            source_tile["y"],
        )

        for destination_tile in tiles:
            destination_coord = Coord(
                destination_tile["x"],
                destination_tile["y"],
            )

            hops = route(
                source_coord,
                destination_coord,
            )

            pairs.append(
                {
                    "source": source_tile["name"],
                    "source_id": source_tile["tile_id"],
                    "source_coord": {
                        "x": source_coord.x,
                        "y": source_coord.y,
                    },
                    "destination": destination_tile["name"],
                    "destination_id": destination_tile["tile_id"],
                    "destination_coord": {
                        "x": destination_coord.x,
                        "y": destination_coord.y,
                    },
                    "route": [
                        direction.value
                        for direction in hops
                    ],
                    "hop_count": (
                        0
                        if hops == [Direction.LOCAL]
                        else len(hops)
                    ),
                }
            )

    return {
        "mesh": {
            "x": MESH_X,
            "y": MESH_Y,
        },
        "tile_count": len(tiles),
        "pair_count": len(pairs),
        "routing": "XY",
        "source": str(SOURCE),
        "pairs": pairs,
    }


def validate_matrix(matrix, tiles):
    expected_count = len(tiles) * len(tiles)

    assert matrix["tile_count"] == len(tiles)
    assert matrix["pair_count"] == expected_count
    assert len(matrix["pairs"]) == expected_count

    tile_by_name = {
        tile["name"]: tile
        for tile in tiles
    }

    seen = set()

    for pair in matrix["pairs"]:
        key = (
            pair["source"],
            pair["destination"],
        )

        assert key not in seen, (
            f"Duplicate source/destination pair: {key}"
        )

        seen.add(key)

        source_tile = tile_by_name[pair["source"]]
        destination_tile = tile_by_name[pair["destination"]]

        assert pair["source_id"] == source_tile["tile_id"]
        assert pair["destination_id"] == destination_tile["tile_id"]

        assert pair["source_coord"] == {
            "x": source_tile["x"],
            "y": source_tile["y"],
        }

        assert pair["destination_coord"] == {
            "x": destination_tile["x"],
            "y": destination_tile["y"],
        }

        expected_route = [
            direction.value
            for direction in route(
                Coord(
                    source_tile["x"],
                    source_tile["y"],
                ),
                Coord(
                    destination_tile["x"],
                    destination_tile["y"],
                ),
            )
        ]

        assert pair["route"] == expected_route

        if pair["source"] == pair["destination"]:
            assert pair["route"] == ["LOCAL"]
            assert pair["hop_count"] == 0
        else:
            assert "LOCAL" not in pair["route"]
            assert pair["hop_count"] == len(pair["route"])

    assert len(seen) == expected_count


def main():
    print("=" * 68)
    print("PQ-ATTEST P1-4 NoC PAIR MATRIX GENERATOR")
    print("=" * 68)
    print(f"SOURCE      : {SOURCE}")

    tiles = load_authoritative_tile_map()

    matrix = generate_matrix(tiles)

    validate_matrix(
        matrix,
        tiles,
    )

    OUTPUT.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    OUTPUT.write_text(
        json.dumps(
            matrix,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    print(f"TILES       : {len(tiles)}")
    print(f"PAIRS       : {len(matrix['pairs'])}")
    print("ROUTING     : XY")
    print(f"OUTPUT      : {OUTPUT}")
    print("VALIDATION  : PASS")
    print("=" * 68)


if __name__ == "__main__":
    main()