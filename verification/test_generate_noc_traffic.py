import pytest
import json
import copy
from pathlib import Path
from verification.generate_noc_traffic import generate_traffic, verify_noc_traffic

def get_pairs():
    path = Path("software/noc_pair_matrix.json")
    if not path.exists():
        return []
    return json.loads(path.read_text())["pairs"]

def test_determinism():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic1 = generate_traffic(pairs)
    traffic2 = generate_traffic(pairs)
    assert traffic1 == traffic2
    
def test_correct_traffic():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    verify_noc_traffic(traffic, pairs)

def test_wrong_source():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["source"] = "TILE_SPOOF_XYZ"
    with pytest.raises(ValueError, match="wrong source"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_destination():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["destination"] = "TILE_SPOOF_XYZ"
    with pytest.raises(ValueError, match="wrong destination"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_source_id():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["source_id"] = 99
    with pytest.raises(ValueError, match="wrong source ID"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_destination_id():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["destination_id"] = 99
    with pytest.raises(ValueError, match="wrong destination ID"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_coordinate():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["source_coord"] = {"x": 9, "y": 9}
    with pytest.raises(ValueError, match="wrong coordinate"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_route():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["route"] = ["EAST", "EAST", "EAST", "EAST"]
    with pytest.raises(ValueError, match="wrong route"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_hop_count():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["hop_count"] = 99
    with pytest.raises(ValueError, match="wrong hop count"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_message_type():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["msg_type_id"] = 99
    with pytest.raises(ValueError, match="wrong message type"):
        verify_noc_traffic(traffic, pairs)

def test_wrong_vc():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic[0]["vc_id"] = 99
    with pytest.raises(ValueError, match="wrong VC"):
        verify_noc_traffic(traffic, pairs)

def test_duplicate_transaction_id():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    if len(traffic) > 1:
        traffic[1]["transaction_id"] = traffic[0]["transaction_id"]
        with pytest.raises(ValueError, match="duplicate transaction ID"):
            verify_noc_traffic(traffic, pairs)

def test_missing_transaction():
    pairs = get_pairs()
    if not pairs:
        pytest.skip("No pair matrix found")
    traffic = generate_traffic(pairs)
    traffic.pop()
    with pytest.raises(ValueError, match="missing transaction"):
        verify_noc_traffic(traffic, pairs)
