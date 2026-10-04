"""Эталонные данные для сверки iOS-движка с Python.

Прогоняет ролик через YOLO (predict + track) и сохраняет JSON:
  frames[].raw     — сырые детекции [x1,y1,x2,y2,conf, 17*(x,y,v)] — вход для Swift-трекера;
  frames[].tracked — детекции после ByteTrack [id,x1,y1,x2,y2, 17*(x,y,v)] — вход для Swift-аналитики;
  expected         — итоговые счётчики Python (по tracked);
  config           — параметры подсчёта, с которыми получен результат.

python tools/make_golden.py --source clip.mp4 --config config.img1761.yaml --out golden.json --imgsz 640
"""
import argparse
import json
import sys
from pathlib import Path

import cv2

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from mantis.analytics import Analytics, Detection  # noqa: E402
from mantis.config import load_config  # noqa: E402
from mantis.geometry import to_pixels  # noqa: E402
from mantis.source import FileSource  # noqa: E402


def r1(v):
    return round(float(v), 1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--config", default=None)
    ap.add_argument("--out", default="golden.json")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--device", default="cpu")
    args = ap.parse_args()

    from ultralytics import YOLO

    cfg = load_config(args.config)
    m = cfg["model"]
    det_model, trk_model = YOLO(m["weights"]), YOLO(m["weights"])
    src = FileSource(args.source, rotate=cfg["source"]["rotate"], max_side=cfg["source"]["max_side"])

    frames, analytics, w, h = [], None, 0, 0
    for t, frame, _ in src.frames():
        if analytics is None:
            h, w = frame.shape[:2]
            analytics = Analytics(cfg, to_pixels(cfg["count_line"], w, h), to_pixels(cfg["showcase_zone"], w, h),
                                  frame_size=(w, h))
        kw = dict(conf=m["conf"], imgsz=args.imgsz, device=args.device, classes=[0], verbose=False)
        raw = det_model.predict(frame, **kw)[0]
        trk = trk_model.track(frame, persist=True, tracker=m["tracker"], **kw)[0]

        raw_list = []
        for b, c, k in zip(raw.boxes.xyxy.tolist(), raw.boxes.conf.tolist(), raw.keypoints.data.tolist()):
            raw_list.append([r1(x) for x in b] + [round(c, 3)] + [r1(v) if i % 3 < 2 else round(v, 3)
                                                                    for i, v in enumerate(sum(k, []))])
        tracked, dets = [], []
        if trk.boxes is not None and trk.boxes.id is not None:
            for i, b, k in zip(trk.boxes.id.int().tolist(), trk.boxes.xyxy.tolist(), trk.keypoints.data.tolist()):
                tracked.append([i] + [r1(x) for x in b] + [r1(v) if j % 3 < 2 else round(v, 3)
                                                           for j, v in enumerate(sum(k, []))])
                # аналитику кормим ровно теми округлёнными числами, что попадут в JSON
                row = tracked[-1]
                kp = [row[5 + 3 * n: 8 + 3 * n] for n in range(17)]
                dets.append(Detection(i, tuple(row[1:5]), kp))
        analytics.update(t, dets)
        frames.append({"t": round(t, 4), "raw": raw_list, "tracked": tracked})

    analytics.close_all()
    out = {
        "source": Path(args.source).name, "fps": src.fps, "width": w, "height": h, "imgsz": args.imgsz,
        "config": {k: cfg[k] for k in ("count_line", "showcase_zone", "slowdown", "look", "tracking")},
        "expected": analytics.report(),
        "expected_tracks": len(analytics.finished),
        "frames": frames,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print(json.dumps(out["expected"], ensure_ascii=False), "tracks:", out["expected_tracks"], "frames:", len(frames))


if __name__ == "__main__":
    main()
