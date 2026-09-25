import argparse
import json
from pathlib import Path
from verification.sv_vector_bridge import (
    MESSAGE_PAYLOAD_FLITS,
    MESSAGE_VC,
)

MSG_NAMES = {
    0: "MSG_MEM_RD_REQ",
    1: "MSG_MEM_RD_RESP",
    2: "MSG_MEM_WR_REQ",
    3: "MSG_MEM_WR_RESP",
    4: "MSG_ATTEST_CHALLENGE",
    5: "MSG_ATTEST_RESPONSE",
    6: "MSG_ATTEST_GRANT",
    7: "MSG_ATTEST_REVOKE",
}

VC_NAMES = {
    0: "VC_REQUEST",
    1: "VC_RESPONSE",
    2: "VC_ATTESTATION",
}

def generate_payload(msg_type: int, seed: int) -> list[str]:
    count = MESSAGE_PAYLOAD_FLITS[msg_type]
    payload = []
    for i in range(count):
        val = ((seed & 0xFFFF) << 16) | (msg_type << 8) | (i + 1)
        payload.append(f"0x{val:08X}")
    return payload

def generate_traffic(pairs: list[dict]) -> list[dict]:
    traffic = []
    msg_types = list(MSG_NAMES.keys())
    
    for i, pair in enumerate(pairs):
        tx_id = f"T{i+1:04d}"
        msg_type = msg_types[i % len(msg_types)]
        vc_id = MESSAGE_VC[msg_type]
        
        seed = (pair["source_id"] << 8) | pair["destination_id"]
        
        record = {
            "transaction_id": tx_id,
            "source": pair["source"],
            "source_id": pair["source_id"],
            "source_coord": pair["source_coord"],
            "destination": pair["destination"],
            "destination_id": pair["destination_id"],
            "destination_coord": pair["destination_coord"],
            "route": pair["route"],
            "hop_count": pair["hop_count"],
            "msg_type": MSG_NAMES[msg_type],
            "msg_type_id": msg_type,
            "vc": VC_NAMES[vc_id],
            "vc_id": vc_id,
            "payload": generate_payload(msg_type, seed)
        }
        traffic.append(record)
    return traffic

def verify_noc_traffic(traffic: list[dict], pairs: list[dict]):
    if not traffic:
        raise ValueError("missing transaction")
        
    tx_ids = set()
    for i, t in enumerate(traffic):
        if t["transaction_id"] in tx_ids:
            raise ValueError("duplicate transaction ID")
        tx_ids.add(t["transaction_id"])
        
        # We assume pairs matrix is the authoritative source for topology
        # since it is verified by verify_noc_pair_matrix.py
        p = pairs[i] if i < len(pairs) else None
        if not p:
            raise ValueError("extra transaction")
            
        if t["source"] != p["source"]:
            raise ValueError("wrong source")
        if t["destination"] != p["destination"]:
            raise ValueError("wrong destination")
        if t["source_id"] != p["source_id"]:
            raise ValueError("wrong source ID")
        if t["destination_id"] != p["destination_id"]:
            raise ValueError("wrong destination ID")
        if t["source_coord"] != p["source_coord"]:
            raise ValueError("wrong coordinate")
        if t["destination_coord"] != p["destination_coord"]:
            raise ValueError("wrong coordinate")
        if t["route"] != p["route"]:
            raise ValueError("wrong route")
        if t["hop_count"] != p["hop_count"]:
            raise ValueError("wrong hop count")
        
        msg_id = t["msg_type_id"]
        if msg_id not in MESSAGE_PAYLOAD_FLITS:
            raise ValueError("wrong message type")
            
        if t["msg_type"] != MSG_NAMES[msg_id]:
            raise ValueError("wrong message type")
        
        if t["vc_id"] != MESSAGE_VC[msg_id]:
            raise ValueError("wrong VC")
            
        if t["vc"] != VC_NAMES[t["vc_id"]]:
            raise ValueError("wrong VC")
            
    if len(traffic) < len(pairs):
        raise ValueError("missing transaction")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, default=Path("software/noc_pair_matrix.json"))
    parser.add_argument("--output", type=Path, default=Path("software/noc_traffic_vectors.json"))
    args = parser.parse_args()

    matrix_data = json.loads(args.matrix.read_text(encoding="utf-8"))
    pairs = matrix_data.get("pairs", [])
    
    traffic = generate_traffic(pairs)
    verify_noc_traffic(traffic, pairs)

    output_data = {"traffic": traffic}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output_data, indent=2), encoding="utf-8")
    
    print(f"Generated {len(traffic)} deterministic traffic vectors.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
