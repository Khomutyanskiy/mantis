"""Загрузка конфига с подстановкой значений по умолчанию."""
from __future__ import annotations

import copy
from pathlib import Path

import yaml

DEFAULTS = {
    "model": {"weights": "yolo11n-pose.pt", "conf": 0.35, "imgsz": 1280, "device": None, "tracker": "bytetrack.yaml"},
    "source": {"rotate": "auto", "max_side": 1920},
    "count_line": [[0.5, 0.05], [0.5, 0.95]],
    "showcase_zone": [[0.05, 0.05], [0.95, 0.05], [0.95, 0.95], [0.05, 0.95]],
    "slowdown": {"speed_threshold": 0.30, "min_slow_seconds": 1.0, "dwell_seconds": 8.0, "smoothing_seconds": 0.5,
                 "focal_ratio": 0.8, "depth_window_seconds": 1.0, "dwell_only_with_zone": True},
    "look": {"showcase_direction": "camera", "max_yaw": 0.35, "min_side_yaw": 0.35,
             "min_look_seconds": 0.6, "min_keypoint_conf": 0.5},
    "tracking": {"lost_timeout_seconds": 2.0, "min_track_seconds": 0.5},
    "output": {"dir": "output", "save_video": True, "show": False,
               "display_height": 900, "display_width": 1600, "fullscreen": False, "summary_every_seconds": 10},
}


def _merge(base: dict, override: dict) -> dict:
    out = copy.deepcopy(base)
    for k, v in (override or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = v
    return out


def load_config(path: str | None) -> dict:
    if not path:
        return copy.deepcopy(DEFAULTS)
    with open(Path(path), encoding="utf-8") as f:
        return _merge(DEFAULTS, yaml.safe_load(f) or {})
