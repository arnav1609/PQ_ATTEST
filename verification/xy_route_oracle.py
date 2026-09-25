from dataclasses import dataclass
from enum import Enum


class Direction(str, Enum):
    NORTH = "NORTH"
    SOUTH = "SOUTH"
    EAST = "EAST"
    WEST = "WEST"
    LOCAL = "LOCAL"


@dataclass(frozen=True)
class Coord:
    x: int
    y: int


def next_hop(current: Coord, destination: Coord) -> Direction:
    """
    Deterministic XY routing oracle.

    Routing priority:
      1. Resolve X dimension completely.
      2. Resolve Y dimension.
      3. LOCAL when source == destination.
    """

    if current == destination:
        return Direction.LOCAL

    # X dimension has priority.
    if current.x < destination.x:
        return Direction.EAST

    if current.x > destination.x:
        return Direction.WEST

    # X is aligned; resolve Y.
    if current.y < destination.y:
        return Direction.SOUTH

    if current.y > destination.y:
        return Direction.NORTH

    # Defensive fallback; equality was handled above.
    return Direction.LOCAL


def route(source: Coord, destination: Coord) -> list[Direction]:
    """
    Return the complete deterministic XY route.

    The source coordinate itself is not included as a hop.
    LOCAL is returned for source == destination.
    """

    current = source
    hops = []

    while current != destination:
        direction = next_hop(current, destination)
        hops.append(direction)

        if direction == Direction.EAST:
            current = Coord(current.x + 1, current.y)

        elif direction == Direction.WEST:
            current = Coord(current.x - 1, current.y)

        elif direction == Direction.SOUTH:
            current = Coord(current.x, current.y + 1)

        elif direction == Direction.NORTH:
            current = Coord(current.x, current.y - 1)

        else:
            raise RuntimeError(
                "LOCAL returned before destination was reached"
            )

    if not hops:
        return [Direction.LOCAL]

    return hops


def main():
    test_cases = [
        (Coord(0, 0), Coord(0, 0)),
        (Coord(0, 0), Coord(2, 0)),
        (Coord(0, 0), Coord(0, 1)),
        (Coord(0, 0), Coord(2, 1)),
        (Coord(2, 1), Coord(0, 0)),
        (Coord(1, 1), Coord(2, 0)),
    ]

    print("=" * 68)
    print("PQ-ATTEST P1-3 XY ROUTING ORACLE")
    print("=" * 68)

    for source, destination in test_cases:
        hops = route(source, destination)
        hop_text = " -> ".join(h.value for h in hops)

        print(
            f"  ({source.x},{source.y})"
            f" -> ({destination.x},{destination.y})"
            f" : {hop_text}"
        )

    print("=" * 68)


if __name__ == "__main__":
    main()