import json
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
VERIFICATION = ROOT / "verification"

sys.path.insert(0, str(VERIFICATION))

import generate_noc_pair_matrix as generator


def write_mutation(tmp_path, text, name):
    path = tmp_path / f"{name}.sv"
    path.write_text(text, encoding="utf-8")
    return path


def load_source():
    return generator.SOURCE.read_text(encoding="utf-8")


def run_generation(source):
    original = generator.SOURCE

    try:
        generator.SOURCE = source

        tiles = generator.load_authoritative_tile_map()
        matrix = generator.generate_matrix(tiles)
        generator.validate_matrix(matrix, tiles)

        return True

    except (AssertionError, RuntimeError, ValueError, KeyError):
        return False

    finally:
        generator.SOURCE = original


# ---------------------------------------------------------------------------
# Correct authoritative source
# ---------------------------------------------------------------------------

def test_authoritative_source_generates_36_pairs():
    tiles = generator.load_authoritative_tile_map()

    assert len(tiles) == 6

    matrix = generator.generate_matrix(tiles)

    generator.validate_matrix(matrix, tiles)

    assert matrix["tile_count"] == 6
    assert matrix["pair_count"] == 36
    assert len(matrix["pairs"]) == 36


# ---------------------------------------------------------------------------
# Mutation: duplicate tile ID
# ---------------------------------------------------------------------------

def test_duplicate_tile_id_fails(tmp_path):
    text = load_source()

    mutated = text.replace(
        "TILE_SPOOF  = 'd5",
        "TILE_SPOOF  = 'd4",
        1,
    )

    source = write_mutation(
        tmp_path,
        mutated,
        "duplicate_tile_id",
    )

    assert not run_generation(source)


# ---------------------------------------------------------------------------
# Mutation: duplicate coordinate
# ---------------------------------------------------------------------------

def test_duplicate_coordinate_fails(tmp_path):
    text = load_source()

    mutated = text.replace(
        "TILE_SPOOF:  begin coord.x = 3'd2; coord.y = 3'd1; end",
        "TILE_SPOOF:  begin coord.x = 3'd1; coord.y = 3'd1; end",
        1,
    )

    if mutated == text:
        pytest.fail(
            "Could not locate TILE_SPOOF coordinate mapping"
        )

    source = write_mutation(
        tmp_path,
        mutated,
        "duplicate_coordinate",
    )

    assert not run_generation(source)


# ---------------------------------------------------------------------------
# Mutation: out-of-bounds coordinate
# ---------------------------------------------------------------------------

def test_out_of_bounds_coordinate_fails(tmp_path):
    text = load_source()

    mutated = text.replace(
        "TILE_SPOOF:  begin coord.x = 3'd2; coord.y = 3'd1; end",
        "TILE_SPOOF:  begin coord.x = 3'd3; coord.y = 3'd1; end",
        1,
    )

    if mutated == text:
        pytest.fail(
            "Could not locate TILE_SPOOF coordinate mapping"
        )

    source = write_mutation(
        tmp_path,
        mutated,
        "out_of_bounds",
    )

    assert not run_generation(source)


# ---------------------------------------------------------------------------
# Mutation: missing coordinate
# ---------------------------------------------------------------------------

def test_missing_coordinate_fails(tmp_path):
    text = load_source()

    mutated = text.replace(
        "TILE_SPOOF:  begin coord.x = 3'd2; coord.y = 3'd1; end",
        "",
        1,
    )

    if mutated == text:
        pytest.fail(
            "Could not locate TILE_SPOOF coordinate mapping"
        )

    source = write_mutation(
        tmp_path,
        mutated,
        "missing_coordinate",
    )

    assert not run_generation(source)


# ---------------------------------------------------------------------------
# Matrix completeness
# ---------------------------------------------------------------------------

def test_matrix_has_all_36_unique_pairs():
    tiles = generator.load_authoritative_tile_map()

    matrix = generator.generate_matrix(tiles)

    pairs = {
        (
            pair["source"],
            pair["destination"],
        )
        for pair in matrix["pairs"]
    }

    assert len(pairs) == 36


# ---------------------------------------------------------------------------
# Determinism
# ---------------------------------------------------------------------------

def test_matrix_is_deterministic():
    tiles = generator.load_authoritative_tile_map()

    matrix_a = generator.generate_matrix(tiles)
    matrix_b = generator.generate_matrix(tiles)

    assert matrix_a == matrix_b


# ---------------------------------------------------------------------------
# Route validity
# ---------------------------------------------------------------------------

def test_xy_route_is_present_for_every_nonlocal_pair():
    tiles = generator.load_authoritative_tile_map()

    matrix = generator.generate_matrix(tiles)

    for pair in matrix["pairs"]:

        if pair["source"] == pair["destination"]:
            assert pair["route"] == ["LOCAL"]
            assert pair["hop_count"] == 0

        else:
            assert pair["route"]
            assert "LOCAL" not in pair["route"]
            assert pair["hop_count"] > 0


# ---------------------------------------------------------------------------
# JSON serialization
# ---------------------------------------------------------------------------

def test_generated_json_matches_validated_matrix(tmp_path):
    tiles = generator.load_authoritative_tile_map()

    matrix = generator.generate_matrix(tiles)

    generator.validate_matrix(
        matrix,
        tiles,
    )

    output = tmp_path / "noc_pair_matrix.json"

    output.write_text(
        json.dumps(matrix, indent=2),
        encoding="utf-8",
    )

    loaded = json.loads(
        output.read_text(encoding="utf-8")
    )

    assert loaded == matrix