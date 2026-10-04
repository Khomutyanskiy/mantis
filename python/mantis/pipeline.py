"""Видеопоток → детекция + трекинг (YOLO-pose + ByteTrack) → аналитика → CSV/JSON, окно и размеченное видео.

Два режима:
  пакетный (по умолчанию) — файл обрабатывается кадр за кадром, без пропусков, время = номер кадра / fps;
  live — поведение живой камеры. Показ и распознавание развязаны:
         * основной поток показывает КАЖДЫЙ кадр камеры в её темпе — видео идёт плавно,
           независимо от того, сколько людей в кадре и как быстро работает нейросеть;
         * фоновый поток распознавания берёт самый свежий кадр, считает людей и публикует результат;
         * на каждый показываемый кадр накладываются последние готовые рамки и счётчики.
"""
from __future__ import annotations

import csv
import json
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional, Tuple

import cv2
import numpy as np

from .analytics import Analytics, Detection
from .geometry import to_pixels
from .source import FileSource, LiveSource

GREEN, YELLOW, RED, WHITE, GRAY = (80, 200, 80), (0, 210, 255), (60, 60, 230), (255, 255, 255), (150, 150, 150)
WINDOW = "Mantis"


# --------------------------------------------------------------------------- отрисовка
@dataclass
class Overlay:
    """Снимок результатов распознавания для отрисовки (неизменяемый, безопасно передаётся между потоками)."""
    boxes: List[Tuple[Tuple[int, int, int, int], tuple, str]] = field(default_factory=list)  # (рамка, цвет, подпись)
    counters: dict = field(default_factory=lambda: {"passed": 0, "passed_forward": 0, "passed_backward": 0,
                                                    "slowed": 0, "looked": 0})
    t: float = 0.0  # время кадра, по которому получен результат


def make_overlay(analytics: Analytics, t: float) -> Overlay:
    boxes = []
    for tr in analytics.tracks.values():
        if tr.box is None or tr.last_t < analytics.last_t:
            continue  # человек не виден в текущем кадре
        color = YELLOW if tr.looked else (GREEN if tr.slowed else (WHITE if tr.passed else GRAY))
        tags = [f"#{tr.track_id}"]
        if tr.speed is not None:
            tags.append(f"{tr.speed:.2f}")
        if tr.looking_now:
            tags.append("LOOK")
        boxes.append((tuple(map(int, tr.box)), color, " ".join(tags)))
    return Overlay(boxes, dict(analytics.counters), t)


def draw(frame, line, zone, ov: Overlay, stats: Optional[list] = None) -> None:
    c = ov.counters
    scale = max(1.0, frame.shape[0] / 1080)  # крупнее шрифт и линии на больших кадрах
    th = max(2, int(2 * scale))

    overlay = frame.copy()
    cv2.fillPoly(overlay, [np.array(zone, dtype=np.int32)], (255, 180, 0))
    cv2.addWeighted(overlay, 0.15, frame, 0.85, 0, frame)
    cv2.polylines(frame, [np.array(zone, dtype=np.int32)], True, (255, 180, 0), th)
    cv2.line(frame, tuple(map(int, line[0])), tuple(map(int, line[1])), RED, th + 1)

    for (x1, y1, x2, y2), color, label in ov.boxes:
        cv2.rectangle(frame, (x1, y1), (x2, y2), color, th)
        cv2.putText(frame, label, (x1, max(int(15 * scale), y1 - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.5 * scale, color, th)

    lines = [f"Passed:  {c['passed']}  (fwd {c['passed_forward']} / back {c['passed_backward']})",
             f"Slowed:  {c['slowed']}",
             f"Looked:  {c['looked']}"] + (stats or [])
    fs, lh = 0.65 * scale, int(26 * scale)
    width = int(max(cv2.getTextSize(s, cv2.FONT_HERSHEY_SIMPLEX, fs, th)[0][0] for s in lines) + 24 * scale)
    cv2.rectangle(frame, (8, 8), (8 + width, int(20 * scale) + lh * len(lines)), (0, 0, 0), -1)
    for i, s in enumerate(lines):
        cv2.putText(frame, s, (int(16 * scale), int(32 * scale) + lh * i), cv2.FONT_HERSHEY_SIMPLEX, fs,
                    WHITE if i < 3 else (180, 180, 180), th)


def fit_to_screen(frame, max_h: int, max_w: int):
    h, w = frame.shape[:2]
    k = min(max_h / h, max_w / w, 1.0)
    return frame if k >= 1.0 else cv2.resize(frame, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)


# --------------------------------------------------------------------------- общие части
class Recorder:
    """События в CSV, итоговые tracks.csv / summary.json."""

    def __init__(self, cfg: dict, source: str, live: bool):
        self.source, self.live = source, live
        self.out_dir = Path(cfg["output"]["dir"]) / datetime.now().strftime("%Y%m%d_%H%M%S")
        self.out_dir.mkdir(parents=True, exist_ok=True)
        self._f = open(self.out_dir / "events.csv", "w", newline="", encoding="utf-8")
        self._csv = csv.DictWriter(self._f, fieldnames=["t", "wall_time", "track_id", "event", "direction"])
        self._csv.writeheader()
        self.start_wall = datetime.now()

    def events(self, events: list) -> None:
        for e in events:
            wall = datetime.fromtimestamp(self.start_wall.timestamp() + e["t"])
            self._csv.writerow({**e, "t": round(e["t"], 2), "wall_time": wall.isoformat(timespec="seconds")})
            if self.live:
                print(f"[{wall:%H:%M:%S}] #{e['track_id']} {e['event']} {e['direction']}", flush=True)
        if events:
            self._f.flush()

    def report(self, analytics: Optional[Analytics], **extra) -> dict:
        a = analytics.report() if analytics else {}
        return {"source": self.source, "mode": "live" if self.live else "batch", **extra,
                "active_tracks": len(analytics.tracks) if analytics else 0,
                "finished_tracks": len(analytics.finished) if analytics else 0, **a,
                "output_dir": str(self.out_dir)}

    def summary(self, report: dict) -> None:
        tmp = self.out_dir / "summary.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(report, f, ensure_ascii=False, indent=2)
        tmp.replace(self.out_dir / "summary.json")

    def finish(self, analytics: Optional[Analytics], **extra) -> dict:
        self._f.close()
        if analytics is None:
            raise RuntimeError("Не получено ни одного кадра")
        analytics.close_all()
        if analytics.finished:
            with open(self.out_dir / "tracks.csv", "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=list(analytics.finished[0].keys()))
                w.writeheader()
                w.writerows(analytics.finished)
        rep = self.report(analytics, **extra)
        self.summary(rep)
        return rep


def detect(model, frame, track_kw) -> List[Detection]:
    res = model.track(frame, **track_kw)[0]
    if res.boxes is None or res.boxes.id is None:
        return []
    ids = res.boxes.id.int().tolist()
    boxes = res.boxes.xyxy.tolist()
    kpts = res.keypoints.data.tolist() if res.keypoints is not None else [None] * len(ids)
    return [Detection(i, tuple(b), k) for i, b, k in zip(ids, boxes, kpts)]


class Window:
    def __init__(self, cfg: dict):
        o = cfg["output"]
        self.enabled = o["show"]
        self.fullscreen = bool(o.get("fullscreen"))
        self.max_h, self.max_w = o["display_height"], o["display_width"]
        self.paused = False
        if self.enabled:
            cv2.namedWindow(WINDOW, cv2.WINDOW_NORMAL)
            if self.fullscreen:
                cv2.setWindowProperty(WINDOW, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)

    def show(self, frame) -> bool:
        """Показать кадр и обработать клавиши. False — пользователь закрыл окно."""
        if not self.enabled:
            return True
        cv2.imshow(WINDOW, frame if self.fullscreen else fit_to_screen(frame, self.max_h, self.max_w))
        while True:
            key = cv2.waitKey(1 if not self.paused else 50) & 0xFF
            if key in (27, ord("q")):
                return False
            if key == ord("f"):  # во весь экран вкл/выкл
                self.fullscreen = not self.fullscreen
                cv2.setWindowProperty(WINDOW, cv2.WND_PROP_FULLSCREEN,
                                      cv2.WINDOW_FULLSCREEN if self.fullscreen else cv2.WINDOW_NORMAL)
            if key == ord(" "):  # пауза: картинка замирает, «камера» и распознавание продолжают идти
                self.paused = not self.paused
            if not self.paused:
                return True

    def close(self) -> None:
        if self.enabled:
            cv2.destroyAllWindows()


def _load_model(cfg: dict):
    from ultralytics import YOLO  # импорт здесь, чтобы аналитика тестировалась без torch
    m = cfg["model"]
    model = YOLO(m["weights"])
    track_kw = dict(persist=True, conf=m["conf"], imgsz=m["imgsz"], device=m["device"],
                    tracker=m["tracker"], classes=[0], verbose=False)
    return model, track_kw


# --------------------------------------------------------------------------- пакетный режим
def run_batch(source: str, cfg: dict, max_frames: Optional[int] = None) -> dict:
    model, track_kw = _load_model(cfg)
    src = FileSource(source, rotate=cfg["source"]["rotate"], max_side=cfg["source"]["max_side"])
    rec = Recorder(cfg, source, live=False)
    win = Window(cfg)
    save_video = cfg["output"]["save_video"]
    if src.rotation:
        print(f"[source] видео повёрнуто на {src.rotation}° по метаданным — разворачиваю", flush=True)

    analytics = line = zone = writer = None
    n, t, t0 = 0, 0.0, time.time()
    try:
        for t, frame, _ in src.frames():
            if analytics is None:
                h, w = frame.shape[:2]
                line, zone = to_pixels(cfg["count_line"], w, h), to_pixels(cfg["showcase_zone"], w, h)
                analytics = Analytics(cfg, line, zone, frame_size=(w, h))
            rec.events(analytics.update(t, detect(model, frame, track_kw)))
            n += 1
            if win.enabled or save_video:
                draw(frame, line, zone, make_overlay(analytics, t))
                if save_video:
                    if writer is None:
                        writer = cv2.VideoWriter(str(rec.out_dir / "annotated.mp4"), cv2.VideoWriter_fourcc(*"mp4v"),
                                                 src.fps, (frame.shape[1], frame.shape[0]))
                    writer.write(frame)
                if not win.show(frame):
                    break
            if n % 100 == 0:
                c = analytics.counters
                print(f"[{n}] {n / (time.time() - t0):.1f} fps | прошло {c['passed']}, притормозило {c['slowed']}, "
                      f"посмотрело {c['looked']}", flush=True)
            if max_frames and n >= max_frames:
                break
    except KeyboardInterrupt:
        print("Остановлено (Ctrl+C)")
    finally:
        src.close()
        if writer is not None:
            writer.release()
        win.close()
    return rec.finish(analytics, frames_processed=n, seconds=round(t, 1))


# --------------------------------------------------------------------------- live-режим
class DetectorWorker(threading.Thread):
    """Фоновое распознавание: берёт самый свежий кадр, обновляет аналитику, публикует Overlay."""

    def __init__(self, src: LiveSource, model, track_kw, cfg: dict, rec: Recorder, max_frames: Optional[int]):
        super().__init__(daemon=True)
        self.src, self.model, self.track_kw, self.cfg, self.rec = src, model, track_kw, cfg, rec
        self.max_frames = max_frames
        self.analytics: Optional[Analytics] = None
        self.line = self.zone = None
        self.overlay = Overlay()
        self.processed = 0
        self.skipped = 0       # кадров камеры, которые распознавание пропустило (показ их всё равно показал)
        self.fps = 0.0
        self.lag = 0.0         # насколько результат отстаёт от момента прихода кадра
        self.error: Optional[BaseException] = None
        self.done = threading.Event()
        self.ready = threading.Event()  # разметка (линия, зона) готова

    def run(self) -> None:
        try:
            self._loop()
        except BaseException as e:  # noqa: BLE001 — пробрасываем в основной поток
            self.error = e
        finally:
            self.ready.set()
            self.done.set()

    def _loop(self) -> None:
        last_seq, last_summary, tick = 0, time.time(), time.time()
        every = self.cfg["output"]["summary_every_seconds"]
        while not self.done.is_set():
            r = self.src.next_frame(last_seq)
            if r is None:
                return
            seq, t, frame = r
            if last_seq:
                self.skipped += seq - last_seq - 1
            last_seq = seq
            if self.analytics is None:
                h, w = frame.shape[:2]
                self.line = to_pixels(self.cfg["count_line"], w, h)
                self.zone = to_pixels(self.cfg["showcase_zone"], w, h)
                self.analytics = Analytics(self.cfg, self.line, self.zone, frame_size=(w, h))
                self.ready.set()

            dets = detect(self.model, frame, self.track_kw)
            self.rec.events(self.analytics.update(t, dets))
            self.overlay = make_overlay(self.analytics, t)  # атомарная замена ссылки — без блокировок
            self.processed += 1

            now = time.time()
            dt, tick = now - tick, now
            self.fps = 1 / dt if self.fps == 0 else 0.9 * self.fps + 0.1 / max(dt, 1e-6)
            self.lag = time.monotonic() - (self.src.start + t)

            if now - last_summary >= every:
                last_summary = now
                c = self.analytics.counters
                self.rec.summary(self.rec.report(self.analytics, frames_processed=self.processed,
                                                 frames_skipped=self.skipped))
                print(f"--- {datetime.now():%H:%M:%S} | распознавание {self.fps:.1f} fps | прошло {c['passed']}, "
                      f"притормозило {c['slowed']}, посмотрело {c['looked']}", flush=True)
            if self.max_frames and self.processed >= self.max_frames:
                return

    def stop(self) -> None:
        self.done.set()


def run_live(source: str, cfg: dict, max_frames: Optional[int] = None, loop: bool = False) -> dict:
    model, track_kw = _load_model(cfg)
    m = cfg["model"]
    if m["device"] in (None, "cpu"):
        # Нейросеть на CPU забирает все ядра и душит декодирование/показ видео — оставляем им пару ядер
        import os

        import torch
        torch.set_num_threads(max(1, (os.cpu_count() or 4) - 2))
    # Прогрев модели до старта «камеры», иначе первые секунды распознавание стоит
    model.predict(np.zeros((640, 640, 3), dtype=np.uint8), imgsz=m["imgsz"], device=m["device"], verbose=False)

    src = LiveSource(source, loop=loop, rotate=cfg["source"]["rotate"], max_side=cfg["source"]["max_side"])
    if src.rotation:
        print(f"[source] видео повёрнуто на {src.rotation}° по метаданным — разворачиваю", flush=True)
    rec = Recorder(cfg, source, live=True)
    worker = DetectorWorker(src, model, track_kw, cfg, rec, max_frames)
    worker.start()
    worker.ready.wait()

    win = Window(cfg)
    save_video = cfg["output"]["save_video"]
    writer = None
    shown, last_seq, disp_fps, tick, t = 0, 0, 0.0, time.time(), 0.0
    try:
        # Основной поток: показываем каждый кадр камеры в её темпе
        while not worker.done.is_set():
            r = src.next_frame(last_seq, timeout=0.5)
            if r is None:
                if src._eof:
                    break
                continue
            last_seq, t, frame = r
            frame = frame.copy()  # исходный кадр общий с распознаванием — рисуем на копии
            now = time.time()
            dt, tick = now - tick, now
            disp_fps = 1 / dt if disp_fps == 0 else 0.9 * disp_fps + 0.1 / max(dt, 1e-6)

            if win.enabled or save_video:
                stats = [f"video {disp_fps:4.1f} fps / src {src.fps:.0f}",
                         f"detect {worker.fps:4.1f} fps   lag {worker.lag * 1000:4.0f} ms   t={t:6.1f}s"]
                draw(frame, worker.line, worker.zone, worker.overlay, stats)
                if save_video:
                    if writer is None:
                        writer = cv2.VideoWriter(str(rec.out_dir / "annotated.mp4"), cv2.VideoWriter_fourcc(*"mp4v"),
                                                 src.fps, (frame.shape[1], frame.shape[0]))
                    writer.write(frame)
                if not win.show(frame):
                    break
            shown += 1
    except KeyboardInterrupt:
        print("Остановлено (Ctrl+C)")
    finally:
        worker.stop()
        src.close()
        worker.join(timeout=5)
        if writer is not None:
            writer.release()
        win.close()
    if worker.error:
        raise worker.error
    return rec.finish(worker.analytics, frames_shown=shown, frames_processed=worker.processed,
                      frames_skipped=worker.skipped, seconds=round(t, 1))


def run(source: str, cfg: dict, max_frames: Optional[int] = None, live: bool = False, loop: bool = False) -> dict:
    return run_live(source, cfg, max_frames, loop) if live else run_batch(source, cfg, max_frames)
