import pytest

from verification.sv_vector_bridge import (
    Packet,
    make_flits,
    pack_head_data,
    FLIT_HEAD,
    FLIT_BODY,
    FLIT_TAIL,
    FLIT_HEAD_TAIL,
    VC_REQUEST,
    VC_ATTESTATION,
    MSG_MEM_RD_REQ,
    MSG_ATTEST_CHALLENGE,
)


def test_correct_vector():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_REQUEST,
        payload=(0x12345678,)
    )
    flits = make_flits(packet)

    # correct vector -> PASS
    assert len(flits) == 2
    assert flits[0]["flit_type"] == FLIT_HEAD
    assert flits[1]["flit_type"] == FLIT_TAIL


def test_wrong_header():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_REQUEST,
        payload=(0x12345678,)
    )
    flits = make_flits(packet)

    expected_head = 0x40001000
    assert flits[0]["data"] == expected_head, "wrong header"


def test_wrong_payload():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_REQUEST,
        payload=(0x12345678,)
    )
    flits = make_flits(packet)

    assert flits[1]["data"] == 0x12345678, "wrong payload"

    packet_bad = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_REQUEST,
        payload=(0x12345678, 0xBAD)
    )
    with pytest.raises(ValueError):
        make_flits(packet_bad)


def test_wrong_flit_type():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_REQUEST,
        payload=(0x12345678,)
    )
    flits = make_flits(packet)

    assert flits[0]["flit_type"] == FLIT_HEAD, "wrong flit type for head"
    assert flits[1]["flit_type"] == FLIT_TAIL, "wrong flit type for tail"


def test_wrong_vc():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_REQUEST,
        payload=(0x12345678,)
    )
    flits = make_flits(packet)
    assert flits[0]["vc"] == VC_REQUEST, "wrong VC"

    packet_bad = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_ATTESTATION,
        payload=(0x12345678,)
    )
    with pytest.raises(ValueError):
        make_flits(packet_bad)


def test_wrong_flit_count():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=0,
        dest_y=1,
        msg_type=MSG_ATTEST_CHALLENGE,
        control=0,
        vc=VC_ATTESTATION,
        payload=(1, 2, 3, 4, 5)
    )
    flits = make_flits(packet)
    assert len(flits) == 6, "wrong flit count"


def test_wrong_ordering():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=0,
        dest_y=1,
        msg_type=MSG_ATTEST_CHALLENGE,
        control=0,
        vc=VC_ATTESTATION,
        payload=(1, 2, 3, 4, 5)
    )
    flits = make_flits(packet)
    
    assert flits[0]["flit_type"] == FLIT_HEAD
    for i in range(1, 5):
        assert flits[i]["flit_type"] == FLIT_BODY
    assert flits[5]["flit_type"] == FLIT_TAIL


def test_wrong_length():
    packet = Packet(
        source_x=0,
        source_y=0,
        dest_x=2,
        dest_y=0,
        msg_type=MSG_MEM_RD_REQ,
        control=0,
        vc=VC_REQUEST,
        payload=(0x12345678,)
    )
    head_data = pack_head_data(packet)
    length = (head_data >> 11) & 0x1F
    assert length == 2, "wrong length"

