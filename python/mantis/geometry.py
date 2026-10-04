"""Геометрические примитивы: линия подсчёта и зона витрины."""
from __future__ import annotations

from typing import Sequence, Tuple

Point = Tuple[float, float]


def side_of_line(p: Point, a: Point, b: Point) -> int:
    """С какой стороны от прямой AB лежит точка P: +1, -1 или 0 (на линии)."""
    cross = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
    if cross > 0:
        return 1
    if cross < 0:
        return -1
    return 0


def segments_intersect(p1: Point, p2: Point, a: Point, b: Point) -> bool:
    """Пересекает ли отрезок движения P1→P2 отрезок линии AB (а не её продолжение)."""
    d1 = side_of_line(p1, a, b)
    d2 = side_of_line(p2, a, b)
    d3 = side_of_line(a, p1, p2)
    d4 = side_of_line(b, p1, p2)
    return d1 != d2 and d3 != d4 and d1 != 0 and d2 != 0


def point_in_polygon(p: Point, poly: Sequence[Point]) -> bool:
    """Ray casting: лежит ли точка внутри многоугольника."""
    x, y = p
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            x_cross = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def to_pixels(points: Sequence[Sequence[float]], width: int, height: int) -> list[Point]:
    """Перевод координат из долей кадра (0..1) в пиксели."""
    return [(float(x) * width, float(y) * height) for x, y in points]


def polygon_area(poly: Sequence[Point]) -> float:
    """Площадь многоугольника (формула шнурования)."""
    n = len(poly)
    s = 0.0
    for i in range(n):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % n]
        s += x1 * y2 - x2 * y1
    return abs(s) / 2
