#!/usr/bin/env python3

"""
PQ-ATTEST P3-1
NoC Network Interface Transaction Contract

This file describes only behavior directly established by
noc_network_interface.sv.

It is intentionally NOT a second NoC simulator.

The contract is used by verification infrastructure to define:
    - TX acceptance
    - TX flit sequencing
    - TX ready/valid behavior
    - RX acceptance
    - RX payload sequencing
    - protocol-error consumption
    - transaction-level invariants
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class FlitType(str, Enum):
    HEAD = "FLIT_HEAD"
    BODY = "FLIT_BODY"
    TAIL = "FLIT_TAIL"
    HEAD_TAIL = "FLIT_HEAD_TAIL"


class TxPhase(str, Enum):
    IDLE = "TX_IDLE"
    HEAD = "TX_HEAD"
    PAYLOAD = "TX_PAYLOAD"
    MAC = "TX_MAC"


class RxPhase(str, Enum):
    IDLE = "RX_IDLE"
    PAYLOAD = "RX_PAYLOAD"
    MAC = "RX_MAC"


@dataclass(frozen=True)
class TxHandshake:
    tx_valid: bool
    tx_ready: bool
    tx_dest_ok: bool

    @property
    def accepted(self) -> bool:
        return (
            self.tx_valid
            and self.tx_ready
            and self.tx_dest_ok
        )


@dataclass(frozen=True)
class NocTransfer:
    valid: bool
    ready: bool

    @property
    def transferred(self) -> bool:
        return self.valid and self.ready


@dataclass(frozen=True)
class RxHead:
    destination_ok: bool
    shape_ok: bool
    response_match: bool
    is_memory_response: bool

    @property
    def accepted_by_ni(self) -> bool:
        if not self.destination_ok:
            return False

        if not self.shape_ok:
            return False

        if self.is_memory_response:
            return self.response_match

        return True


def tx_head_flit_type(
    payload_flits: int,
    mac_flits: int,
) -> FlitType:
    """
    The RTL generates HEAD_TAIL only when there is no payload
    and MAC_FLITS == 0.
    """

    if payload_flits == 0 and mac_flits == 0:
        return FlitType.HEAD_TAIL

    return FlitType.HEAD


def tx_payload_flit_type(
    is_last_payload: bool,
    mac_flits: int,
) -> FlitType:
    """
    Payload is TAIL only when it is the final packet flit.

    If MAC flits follow, payload remains BODY.
    """

    if is_last_payload and mac_flits == 0:
        return FlitType.TAIL

    return FlitType.BODY


def tx_mac_flit_type(
    is_last_mac: bool,
) -> FlitType:
    """
    The final MAC flit is TAIL.
    Earlier MAC flits are BODY.
    """

    if is_last_mac:
        return FlitType.TAIL

    return FlitType.BODY


def rx_head_length_valid(
    advertised_length: int,
    payload_flits: int,
    mac_flits: int,
) -> bool:
    """
    RTL condition:

        rx_head.length ==
            1 + payload_flits + MAC_FLITS
    """

    return advertised_length == (
        1
        + payload_flits
        + mac_flits
    )


def rx_protocol_error_must_consume(
    protocol_error: bool,
    noc_rx_ready: bool,
) -> bool:
    """
    RTL assertion:

        rx_protocol_error |-> noc_rx_ready
    """

    if not protocol_error:
        return True

    return noc_rx_ready


def rx_error_must_not_deliver(
    protocol_error: bool,
    head_valid: bool,
    payload_valid: bool,
) -> bool:
    """
    RTL assertion:

        rx_protocol_error |->
            !(rx_head_valid || rx_payload_valid)
    """

    if not protocol_error:
        return True

    return not (
        head_valid
        or payload_valid
    )


def tx_stall_must_hold(
    previous_valid: bool,
    previous_ready: bool,
    current_valid: bool,
) -> bool:
    """
    RTL property:

        noc_tx_valid && !noc_tx_ready
            |=> noc_tx_valid
    """

    if previous_valid and not previous_ready:
        return current_valid

    return True


def validate_tx_flit_type(
    phase: TxPhase,
    flit_type: FlitType,
) -> bool:

    if phase == TxPhase.HEAD:
        return flit_type in {
            FlitType.HEAD,
            FlitType.HEAD_TAIL,
        }

    if phase == TxPhase.PAYLOAD:
        return flit_type in {
            FlitType.BODY,
            FlitType.TAIL,
        }

    if phase == TxPhase.MAC:
        return flit_type in {
            FlitType.BODY,
            FlitType.TAIL,
        }

    return False


def validate_no_local_loopback(
    destination_is_local: bool,
) -> bool:
    """
    This contract deliberately does not decide routing.

    Local delivery is represented by the NI/router architecture.
    """

    return isinstance(
        destination_is_local,
        bool,
    )


def run_self_tests() -> None:

    # ---------------------------------------------------------
    # TX acceptance
    # ---------------------------------------------------------

    assert TxHandshake(
        True,
        True,
        True,
    ).accepted

    assert not TxHandshake(
        True,
        False,
        True,
    ).accepted

    assert not TxHandshake(
        False,
        True,
        True,
    ).accepted

    assert not TxHandshake(
        True,
        True,
        False,
    ).accepted

    # ---------------------------------------------------------
    # TX head
    # ---------------------------------------------------------

    assert (
        tx_head_flit_type(
            payload_flits=0,
            mac_flits=0,
        )
        == FlitType.HEAD_TAIL
    )

    assert (
        tx_head_flit_type(
            payload_flits=1,
            mac_flits=0,
        )
        == FlitType.HEAD
    )

    # ---------------------------------------------------------
    # Payload
    # ---------------------------------------------------------

    assert (
        tx_payload_flit_type(
            is_last_payload=True,
            mac_flits=0,
        )
        == FlitType.TAIL
    )

    assert (
        tx_payload_flit_type(
            is_last_payload=True,
            mac_flits=1,
        )
        == FlitType.BODY
    )

    assert (
        tx_payload_flit_type(
            is_last_payload=False,
            mac_flits=0,
        )
        == FlitType.BODY
    )

    # ---------------------------------------------------------
    # MAC
    # ---------------------------------------------------------

    assert (
        tx_mac_flit_type(
            is_last_mac=True,
        )
        == FlitType.TAIL
    )

    assert (
        tx_mac_flit_type(
            is_last_mac=False,
        )
        == FlitType.BODY
    )

    # ---------------------------------------------------------
    # Length
    # ---------------------------------------------------------

    assert rx_head_length_valid(
        advertised_length=1,
        payload_flits=0,
        mac_flits=0,
    )

    assert rx_head_length_valid(
        advertised_length=3,
        payload_flits=2,
        mac_flits=0,
    )

    assert rx_head_length_valid(
        advertised_length=5,
        payload_flits=2,
        mac_flits=2,
    )

    assert not rx_head_length_valid(
        advertised_length=4,
        payload_flits=2,
        mac_flits=2,
    )

    # ---------------------------------------------------------
    # RX protocol error
    # ---------------------------------------------------------

    assert rx_protocol_error_must_consume(
        False,
        False,
    )

    assert rx_protocol_error_must_consume(
        True,
        True,
    )

    assert not rx_protocol_error_must_consume(
        True,
        False,
    )

    assert rx_error_must_not_deliver(
        True,
        False,
        False,
    )

    assert not rx_error_must_not_deliver(
        True,
        True,
        False,
    )

    # ---------------------------------------------------------
    # TX stall
    # ---------------------------------------------------------

    assert tx_stall_must_hold(
        previous_valid=True,
        previous_ready=False,
        current_valid=True,
    )

    assert not tx_stall_must_hold(
        previous_valid=True,
        previous_ready=False,
        current_valid=False,
    )

    # ---------------------------------------------------------
    # Flit types
    # ---------------------------------------------------------

    assert validate_tx_flit_type(
        TxPhase.HEAD,
        FlitType.HEAD,
    )

    assert validate_tx_flit_type(
        TxPhase.HEAD,
        FlitType.HEAD_TAIL,
    )

    assert validate_tx_flit_type(
        TxPhase.PAYLOAD,
        FlitType.BODY,
    )

    assert validate_tx_flit_type(
        TxPhase.PAYLOAD,
        FlitType.TAIL,
    )

    assert validate_tx_flit_type(
        TxPhase.MAC,
        FlitType.BODY,
    )

    assert validate_tx_flit_type(
        TxPhase.MAC,
        FlitType.TAIL,
    )


if __name__ == "__main__":
    run_self_tests()
    print(
        "P3-1 NI TRANSACTION CONTRACT: PASS"
    )