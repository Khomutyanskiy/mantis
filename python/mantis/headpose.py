"""Оценка поворота головы по ключевым точкам COCO (нос, глаза, уши, плечи).

Это лёгкая эвристика без отдельной нейросети: pose-модель уже даёт точки лица.
yaw — нормированное смещение носа относительно центра головы:
  0      — лицо смотрит прямо в камеру
  < 0    — нос смещён влево по кадру
  > 0    — нос смещён вправо по кадру
  None   — лица не видно (человек спиной к камере / точки ненадёжны)
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Sequence

NOSE, L_EYE, R_EYE, L_EAR, R_EAR, L_SHOULDER, R_SHOULDER = 0, 1, 2, 3, 4, 5, 6


@dataclass
class HeadPose:
    face_visible: bool
    both_eyes: bool
    yaw: Optional[float]


def estimate_head_pose(kpts: Optional[Sequence[Sequence[float]]], min_conf: float = 0.5) -> HeadPose:
    """kpts: 17 точек [x, y, conf] в формате COCO."""
    if kpts is None or len(kpts) < 7:
        return HeadPose(False, False, None)

    def ok(i: int) -> bool:
        return kpts[i][2] >= min_conf

    if not ok(NOSE):
        return HeadPose(False, False, None)

    nose_x = kpts[NOSE][0]
    both_eyes = ok(L_EYE) and ok(R_EYE)

    # Центр и полуширина головы: уши надёжнее всего, затем глаза, затем плечи.
    center = half_w = None
    if ok(L_EAR) and ok(R_EAR):
        center = (kpts[L_EAR][0] + kpts[R_EAR][0]) / 2
        half_w = abs(kpts[L_EAR][0] - kpts[R_EAR][0]) / 2
    elif both_eyes:
        center = (kpts[L_EYE][0] + kpts[R_EYE][0]) / 2
        half_w = abs(kpts[L_EYE][0] - kpts[R_EYE][0])  # межглазное ~ половина ширины головы
    elif ok(L_SHOULDER) and ok(R_SHOULDER):
        center = (kpts[L_SHOULDER][0] + kpts[R_SHOULDER][0]) / 2
        half_w = abs(kpts[L_SHOULDER][0] - kpts[R_SHOULDER][0]) / 4

    if center is None or half_w is None or half_w < 1e-3:
        # Видно нос и одно ухо => голова в профиль. Направление — по тому, с какой стороны ухо.
        ear = L_EAR if ok(L_EAR) else (R_EAR if ok(R_EAR) else None)
        if ear is None:
            return HeadPose(True, both_eyes, None)
        yaw = 1.0 if nose_x > kpts[ear][0] else -1.0
        return HeadPose(True, both_eyes, yaw)

    yaw = (nose_x - center) / half_w
    yaw = max(-1.0, min(1.0, yaw))
    return HeadPose(True, both_eyes, yaw)


def is_looking(pose: HeadPose, direction: str, max_yaw: float, min_side_yaw: float) -> bool:
    """Смотрит ли человек в сторону витрины.

    direction:
      camera — камера стоит в витрине: смотрит = лицо анфас к камере;
      left / right — витрина слева / справа в кадре: голова повёрнута в эту сторону.
    """
    if not pose.face_visible or pose.yaw is None:
        return False
    if direction == "camera":
        return pose.both_eyes and abs(pose.yaw) <= max_yaw
    if direction == "left":
        return pose.yaw <= -min_side_yaw
    if direction == "right":
        return pose.yaw >= min_side_yaw
    raise ValueError(f"Неизвестное направление витрины: {direction}")
