import pytest

from xy_route_oracle import Coord, Direction, next_hop, route


# ---------------------------------------------------------------------------
# Basic directional correctness
# ---------------------------------------------------------------------------

def test_local_route():
    assert next_hop(Coord(0, 0), Coord(0, 0)) == Direction.LOCAL
    assert route(Coord(0, 0), Coord(0, 0)) == [Direction.LOCAL]


def test_east_route():
    assert next_hop(Coord(0, 0), Coord(2, 0)) == Direction.EAST
    assert route(Coord(0, 0), Coord(2, 0)) == [
        Direction.EAST,
        Direction.EAST,
    ]


def test_west_route():
    assert next_hop(Coord(2, 0), Coord(0, 0)) == Direction.WEST
    assert route(Coord(2, 0), Coord(0, 0)) == [
        Direction.WEST,
        Direction.WEST,
    ]


def test_south_route():
    assert next_hop(Coord(0, 0), Coord(0, 1)) == Direction.SOUTH
    assert route(Coord(0, 0), Coord(0, 1)) == [
        Direction.SOUTH,
    ]


def test_north_route():
    assert next_hop(Coord(0, 1), Coord(0, 0)) == Direction.NORTH
    assert route(Coord(0, 1), Coord(0, 0)) == [
        Direction.NORTH,
    ]


# ---------------------------------------------------------------------------
# XY priority
# ---------------------------------------------------------------------------

def test_xy_priority_east_before_south():
    """
    From (0,0) to (2,1), X must be resolved first.
    """

    assert next_hop(Coord(0, 0), Coord(2, 1)) == Direction.EAST

    assert route(Coord(0, 0), Coord(2, 1)) == [
        Direction.EAST,
        Direction.EAST,
        Direction.SOUTH,
    ]


def test_xy_priority_west_before_north():
    """
    From (2,1) to (0,0), X must be resolved before Y.
    """

    assert next_hop(Coord(2, 1), Coord(0, 0)) == Direction.WEST

    assert route(Coord(2, 1), Coord(0, 0)) == [
        Direction.WEST,
        Direction.WEST,
        Direction.NORTH,
    ]


# ---------------------------------------------------------------------------
# Mixed routes
# ---------------------------------------------------------------------------

def test_mixed_route_east_then_north():
    assert route(Coord(1, 1), Coord(2, 0)) == [
        Direction.EAST,
        Direction.NORTH,
    ]


def test_mixed_route_west_then_south():
    assert route(Coord(2, 0), Coord(0, 1)) == [
        Direction.WEST,
        Direction.WEST,
        Direction.SOUTH,
    ]


# ---------------------------------------------------------------------------
# Route correctness properties
# ---------------------------------------------------------------------------

def test_route_reaches_destination():
    cases = [
        (Coord(0, 0), Coord(2, 1)),
        (Coord(2, 1), Coord(0, 0)),
        (Coord(0, 1), Coord(2, 0)),
        (Coord(2, 0), Coord(0, 1)),
        (Coord(1, 0), Coord(1, 1)),
        (Coord(1, 1), Coord(1, 0)),
    ]

    for source, destination in cases:
        current = source

        for direction in route(source, destination):
            if direction == Direction.EAST:
                current = Coord(current.x + 1, current.y)
            elif direction == Direction.WEST:
                current = Coord(current.x - 1, current.y)
            elif direction == Direction.SOUTH:
                current = Coord(current.x, current.y + 1)
            elif direction == Direction.NORTH:
                current = Coord(current.x, current.y - 1)

        assert current == destination


def test_route_never_returns_local_before_destination():
    cases = [
        (Coord(0, 0), Coord(2, 1)),
        (Coord(2, 1), Coord(0, 0)),
        (Coord(0, 1), Coord(2, 0)),
    ]

    for source, destination in cases:
        hops = route(source, destination)

        if source != destination:
            assert Direction.LOCAL not in hops


# ---------------------------------------------------------------------------
# Injected-fault tests
# ---------------------------------------------------------------------------

def test_wrong_x_priority_would_fail():
    """
    Security/verification mutation:
    A faulty XY implementation that chooses SOUTH before EAST
    must not satisfy the expected result.
    """

    actual = next_hop(Coord(0, 0), Coord(2, 1))

    injected_wrong_result = Direction.SOUTH

    assert actual != injected_wrong_result


def test_wrong_y_direction_would_fail():
    """
    Injected fault: SOUTH/NORTH reversed.
    """

    actual = next_hop(Coord(0, 0), Coord(0, 1))

    injected_wrong_result = Direction.NORTH

    assert actual != injected_wrong_result


def test_wrong_x_direction_would_fail():
    """
    Injected fault: EAST/WEST reversed.
    """

    actual = next_hop(Coord(0, 0), Coord(2, 0))

    injected_wrong_result = Direction.WEST

    assert actual != injected_wrong_result


# ---------------------------------------------------------------------------
# Defensive input validation
# ---------------------------------------------------------------------------

def test_invalid_coordinate_type_rejected():
    with pytest.raises(AttributeError):
        next_hop((0, 0), Coord(1, 1))


def test_route_with_non_coordinate_rejected():
    with pytest.raises(AttributeError):
        route((0, 0), Coord(1, 1))