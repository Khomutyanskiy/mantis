"""Разметка линии подсчёта и зоны витрины мышкой на первом кадре.

python tools/calibrate.py --source video.mp4 --out config.yaml [--base config.example.yaml]

1) Кликните 2 точки — линия подсчёта (красная).
2) Кликайте точки многоугольника зоны витрины, Enter — завершить.
   Backspace — отменить последнюю точку, Esc — выйти без сохранения.
"""
import argparse
import sys
from pathlib import Path

import cv2
import numpy as np
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from mantis.config import load_config  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--out", default="config.yaml")
    ap.add_argument("--base", default=None, help="конфиг, остальные параметры которого сохранить")
    ap.add_argument("--frame", type=int, default=0, help="номер кадра для разметки")
    args = ap.parse_args()

    cap = cv2.VideoCapture(int(args.source) if args.source.isdigit() else args.source)
    cap.set(cv2.CAP_PROP_POS_FRAMES, args.frame)
    ok, frame = cap.read()
    cap.release()
    if not ok:
        sys.exit("Не удалось прочитать кадр")
    h, w = frame.shape[:2]

    line, zone = [], []

    def on_click(event, x, y, *_):
        if event == cv2.EVENT_LBUTTONDOWN:
            (line if len(line) < 2 else zone).append((x, y))

    cv2.namedWindow("calibrate")
    cv2.setMouseCallback("calibrate", on_click)
    while True:
        img = frame.copy()
        hint = "Кликните 2 точки линии подсчёта" if len(line) < 2 else "Точки зоны витрины, Enter - готово"
        cv2.putText(img, hint.encode("ascii", "ignore").decode() or "click", (10, 25),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 255), 2)
        for p in line:
            cv2.circle(img, p, 5, (60, 60, 230), -1)
        if len(line) == 2:
            cv2.line(img, line[0], line[1], (60, 60, 230), 2)
        if zone:
            cv2.polylines(img, [np.array(zone, np.int32)], len(zone) > 2, (255, 180, 0), 2)
        cv2.imshow("calibrate", img)
        k = cv2.waitKey(30) & 0xFF
        if k == 27:
            sys.exit("Отменено")
        if k in (8, 127):
            (zone or line).pop() if (zone or line) else None
        if k in (13, 10) and len(line) == 2 and len(zone) >= 3:
            break
    cv2.destroyAllWindows()

    cfg = load_config(args.base)
    cfg["count_line"] = [[round(x / w, 4), round(y / h, 4)] for x, y in line]
    cfg["showcase_zone"] = [[round(x / w, 4), round(y / h, 4)] for x, y in zone]
    with open(args.out, "w", encoding="utf-8") as f:
        yaml.safe_dump(cfg, f, allow_unicode=True, sort_keys=False)
    print(f"Сохранено в {args.out}")


if __name__ == "__main__":
    main()
