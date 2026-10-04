"""Логика подсчёта: прошёл / притормозил / посмотрел. Не зависит от нейросети — легко тестируется."""
from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field
from statistics import median
from typing import Deque, Dict, List, Optional, Sequence, Tuple

from .geometry import Point, point_in_polygon, polygon_area, segments_intersect, side_of_line
from .headpose import estimate_head_pose, is_looking

MAX_DT = 0.5  # секунды; больший разрыв между кадрами не учитываем в накоплении времени


@dataclass
class Detection:
    track_id: int
    box: Tuple[float, float, float, float]  # x1, y1, x2, y2 в пикселях
    keypoints: Optional[Sequence[Sequence[float]]] = None  # 17 x [x, y, conf]

    @property
    def foot(self) -> Point:
        x1, _, x2, y2 = self.box
        return ((x1 + x2) / 2, y2)

    @property
    def height(self) -> float:
        return max(1.0, self.box[3] - self.box[1])


@dataclass
class TrackState:
    track_id: int
    first_t: float
    last_t: float
    history: Deque[Tuple[float, float, float, float]] = field(default_factory=lambda: deque(maxlen=120))
    passed: bool = False
    direction: Optional[str] = None
    zone_time: float = 0.0
    slow_time: float = 0.0
    look_time: float = 0.0
    slowed: bool = False
    looked: bool = False
    speed: Optional[float] = None
    min_speed: Optional[float] = None
    in_zone: bool = False
    looking_now: bool = False
    box: Optional[Tuple[float, float, float, float]] = None

    def summary(self) -> dict:
        return {
            "track_id": self.track_id,
            "first_t": round(self.first_t, 2),
            "last_t": round(self.last_t, 2),
            "duration": round(self.last_t - self.first_t, 2),
            "passed": int(self.passed),
            "direction": self.direction or "",
            "slowed": int(self.slowed),
            "looked": int(self.looked),
            "zone_time": round(self.zone_time, 2),
            "slow_time": round(self.slow_time, 2),
            "look_time": round(self.look_time, 2),
            "min_speed": round(self.min_speed, 3) if self.min_speed is not None else "",
        }


class Analytics:
    def __init__(self, cfg: dict, line: Sequence[Point], zone: Sequence[Point],
                 frame_size: Optional[Tuple[float, float]] = None):
        """frame_size = (ширина, высота) кадра: нужен для учёта движения к камере/от камеры
        и чтобы понять, что зона — весь кадр. Без него — старое поведение."""
        self.cfg = cfg
        self.line = (tuple(line[0]), tuple(line[1]))
        self.zone = [tuple(p) for p in zone]
        self.frame_size = frame_size
        sd = cfg["slowdown"]
        self.focal = sd.get("focal_ratio", 0.0) * max(frame_size) if frame_size else 0.0
        self.zone_is_full = bool(frame_size) and polygon_area(self.zone) >= 0.98 * frame_size[0] * frame_size[1]
        self.tracks: Dict[int, TrackState] = {}
        self.finished: List[dict] = []
        self.last_t = 0.0
        self.counters = {"passed": 0, "passed_forward": 0, "passed_backward": 0, "slowed": 0, "looked": 0}

    # ------------------------------------------------------------------ helpers
    def _speed(self, tr: TrackState) -> Optional[float]:
        """Сглаженная скорость в «ростах в секунду» за окно smoothing_seconds."""
        win = self.cfg["slowdown"]["smoothing_seconds"]
        t_now = tr.history[-1][0]
        pts = [h for h in tr.history if t_now - h[0] <= win]
        if len(pts) < 2 or pts[-1][0] - pts[0][0] < win * 0.5:
            return None
        t0, x0, y0, _ = pts[0]
        t1, x1, y1, _ = pts[-1]
        h = median(p[3] for p in pts)
        dist = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5
        lateral = dist / h / (t1 - t0)
        if self.focal <= 0:
            return lateral
        # Движение к камере/от камеры: человек почти не сдвигается на картинке, но растёт/уменьшается.
        # Расстояние D ~ f/h, поэтому скорость по глубине в «ростах в секунду» = (f/h) * |d ln h / dt|.
        # Наклон ln h по времени — по МНК за окно depth_window_seconds (устойчиво к дрожанию рамки).
        dwin = self.cfg["slowdown"].get("depth_window_seconds", 1.0)
        dp = [p for p in tr.history if t_now - p[0] <= dwin]
        depth = 0.0
        if len(dp) >= 3:
            n = len(dp)
            mt = sum(p[0] for p in dp) / n
            ml = sum(math.log(p[3]) for p in dp) / n
            den = sum((p[0] - mt) * (p[0] - mt) for p in dp)
            if den > 0:
                slope = sum((p[0] - mt) * (math.log(p[3]) - ml) for p in dp) / den
                depth = self.focal / h * abs(slope)
        return (lateral * lateral + depth * depth) ** 0.5

    # ------------------------------------------------------------------ main API
    def update(self, t: float, detections: Sequence[Detection]) -> List[dict]:
        """Обработать один кадр. t — время кадра в секундах. Возвращает новые события."""
        self.last_t = t
        events: List[dict] = []
        sd, lk = self.cfg["slowdown"], self.cfg["look"]

        for det in detections:
            tr = self.tracks.get(det.track_id)
            fx, fy = det.foot
            if tr is None:
                tr = TrackState(det.track_id, t, t, box=det.box)
                tr.history.append((t, fx, fy, det.height))
                self.tracks[det.track_id] = tr
                tr.in_zone = point_in_polygon((fx, fy), self.zone)
                continue

            dt = min(max(t - tr.last_t, 0.0), MAX_DT)
            _, px, py, _ = tr.history[-1]
            tr.history.append((t, fx, fy, det.height))
            tr.last_t = t
            tr.box = det.box

            # 1. Прошёл: отрезок движения ног пересёк линию подсчёта
            if not tr.passed and segments_intersect((px, py), (fx, fy), *self.line):
                tr.passed = True
                side = side_of_line((fx, fy), *self.line)
                tr.direction = "forward" if side > 0 else "backward"
                self.counters["passed"] += 1
                self.counters[f"passed_{tr.direction}"] += 1
                events.append({"t": t, "track_id": tr.track_id, "event": "passed", "direction": tr.direction})

            # 2. Притормозил: медленно в зоне или долго в зоне
            tr.in_zone = point_in_polygon((fx, fy), self.zone)
            tr.speed = self._speed(tr)
            if tr.in_zone:
                tr.zone_time += dt
                if tr.speed is not None:
                    tr.min_speed = tr.speed if tr.min_speed is None else min(tr.min_speed, tr.speed)
                    if tr.speed < sd["speed_threshold"]:
                        tr.slow_time += dt
                # «Долго в зоне» имеет смысл только для зоны у витрины, а не для всего кадра
                dwell_ok = not (self.zone_is_full and sd.get("dwell_only_with_zone", False))
                if not tr.slowed and (tr.slow_time >= sd["min_slow_seconds"]
                                      or (dwell_ok and tr.zone_time >= sd["dwell_seconds"])):
                    tr.slowed = True
                    self.counters["slowed"] += 1
                    events.append({"t": t, "track_id": tr.track_id, "event": "slowed", "direction": ""})

            # 3. Посмотрел: голова повёрнута к витрине, пока человек в зоне
            pose = estimate_head_pose(det.keypoints, lk["min_keypoint_conf"])
            tr.looking_now = tr.in_zone and is_looking(pose, lk["showcase_direction"], lk["max_yaw"], lk["min_side_yaw"])
            if tr.looking_now:
                tr.look_time += dt
                if not tr.looked and tr.look_time >= lk["min_look_seconds"]:
                    tr.looked = True
                    self.counters["looked"] += 1
                    events.append({"t": t, "track_id": tr.track_id, "event": "looked", "direction": ""})

        self._close_lost(t)
        return events

    def _close_lost(self, t: float) -> None:
        timeout = self.cfg["tracking"]["lost_timeout_seconds"]
        for tid in [tid for tid, tr in self.tracks.items() if t - tr.last_t > timeout]:
            self._finish(self.tracks.pop(tid))

    def _finish(self, tr: TrackState) -> None:
        if tr.last_t - tr.first_t >= self.cfg["tracking"]["min_track_seconds"]:
            self.finished.append(tr.summary())

    def close_all(self) -> None:
        for tr in self.tracks.values():
            self._finish(tr)
        self.tracks.clear()

    def report(self) -> dict:
        c = dict(self.counters)
        p = c["passed"]
        c["slowed_rate"] = round(c["slowed"] / p, 3) if p else None
        c["looked_rate"] = round(c["looked"] / p, 3) if p else None
        return c
