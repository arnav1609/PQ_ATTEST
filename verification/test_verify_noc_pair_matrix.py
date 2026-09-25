from __future__ import annotations

import json
from pathlib import Path

import pytest

from verify_noc_pair_matrix import (
    MatrixVerificationError,
    verify_matrix,
)


ROOT = Path(__file__).resolve().parents[1]

MATRIX = ROOT / "software" / "noc_pair_matrix.json"
SOURCE = ROOT / "NOC_PQATTEST.srcs" / "sources_1" / "new" / "NOC_PKG.sv"


def load_matrix() -> dict:
    with MATRIX.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_matrix(tmp_path: Path, data: dict) -> Path:
    path = tmp_path / "mutated_matrix.json"

    with path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)

    return path


def verify_mutation(tmp_path: Path, mutate) -> None:
    data = load_matrix()
    mutate(data)

    mutated = write_matrix(tmp_path, data)

    with pytest.raises(MatrixVerificationError):
        verify_matrix(
            matrix_path=mutated,
            source_path=SOURCE,
        )


def test_correct_matrix_passes():
    result = verify_matrix(
        matrix_path=MATRIX,
        source_path=SOURCE,
    )

    assert result["tiles"] == 6
    assert result["pairs"] == 36
    assert result["routing"] == "XY"


def test_mutated_source_id_fails(tmp_path):
    def mutate(data):
        data["pairs"][1]["source_id"] = 5

    verify_mutation(tmp_path, mutate)


def test_mutated_destination_id_fails(tmp_path):
    def mutate(data):
        data["pairs"][1]["destination_id"] = 5

    verify_mutation(tmp_path, mutate)


def test_mutated_source_coordinate_fails(tmp_path):
    def mutate(data):
        data["pairs"][1]["source_coord"]["x"] = 2

    verify_mutation(tmp_path, mutate)


def test_mutated_destination_coordinate_fails(tmp_path):
    def mutate(data):
        data["pairs"][1]["destination_coord"]["y"] = 1

    verify_mutation(tmp_path, mutate)


def test_mutated_route_direction_fails(tmp_path):
    def mutate(data):
        # Find a non-local route.
        for pair in data["pairs"]:
            if pair["route"] != ["LOCAL"]:
                pair["route"][0] = "LOCAL"
                return

        raise AssertionError("No non-local pair found.")

    verify_mutation(tmp_path, mutate)


def test_mutated_hop_count_fails(tmp_path):
    def mutate(data):
        for pair in data["pairs"]:
            if pair["route"] != ["LOCAL"]:
                pair["hop_count"] += 1
                return

        raise AssertionError("No non-local pair found.")

    verify_mutation(tmp_path, mutate)


def test_duplicate_pair_fails(tmp_path):
    def mutate(data):
        data["pairs"][1] = dict(data["pairs"][0])

    verify_mutation(tmp_path, mutate)


def test_missing_pair_fails(tmp_path):
    def mutate(data):
        data["pairs"].pop()
        data["pair_count"] = 35

    verify_mutation(tmp_path, mutate)


def test_wrong_mesh_dimension_fails(tmp_path):
    def mutate(data):
        data["mesh"]["x"] = 4

    verify_mutation(tmp_path, mutate)


def test_wrong_routing_mode_fails(tmp_path):
    def mutate(data):
        data["routing"] = "WEST_FIRST"

    verify_mutation(tmp_path, mutate)