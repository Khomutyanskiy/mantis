"""Источники кадров.

FileSource — последовательное чтение файла (пакетный режим: каждый кадр, время по номеру кадра).
LiveSource — поведение живой камеры: кадры приходят в реальном темпе, хранится только самый свежий;
             если обработка не успевает, отставшие кадры пропускаются, задержка не копится.
             Подходит для эмуляции камеры из файла и для настоящих RTSP/USB-камер (с переподключением).
"""
from __future__ import annotations

import threading
import time
from pathlib import Path
from typing import Iterator, Optional, Tuple

import cv2

Frame = Tuple[float, "cv2.Mat", int]  # (время кадра в секундах от старта, кадр, сколько кадров пропущено перед ним)


_ROTATIONS = {90: cv2.ROTATE_90_CLOCKWISE, 180: cv2.ROTATE_180, 270: cv2.ROTATE_90_COUNTERCLOCKWISE}


def _open(source: str) -> cv2.VideoCapture:
    if source.isdigit():  # "0" = веб-камера
        cap = cv2.VideoCapture(int(source))
    else:
        # FFmpeg-бэкенд: на macOS бэкенд по умолчанию (AVFoundation) не сообщает поворот видео с телефона.
        # Просим аппаратное декодирование (VideoToolbox / VAAPI / NVDEC), если сборка OpenCV его умеет.
        cap = cv2.VideoCapture(source, cv2.CAP_FFMPEG,
                               [cv2.CAP_PROP_HW_ACCELERATION, cv2.VIDEO_ACCELERATION_ANY])
        if not cap.isOpened():
            cap = cv2.VideoCapture(source, cv2.CAP_FFMPEG)
        if not cap.isOpened():
            cap = cv2.VideoCapture(source)
    if not cap.isOpened():
        if "://" not in source and not source.isdigit() and not Path(source).exists():
            raise RuntimeError(f"Файл не найден: {Path(source).resolve()}")
        raise RuntimeError(f"Не удалось открыть источник: {source}")
    # Поворот применяем сами (одинаково на всех ОС), встроенный автоповорот OpenCV отключаем
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 0)
    return cap


def resolve_rotation(cap: cv2.VideoCapture, rotate="auto") -> int:
    """Угол поворота кадра по часовой: из метаданных видео (auto) или заданный вручную (0/90/180/270)."""
    if rotate in (None, "auto"):
        angle = int(round(cap.get(cv2.CAP_PROP_ORIENTATION_META) or 0))
    else:
        angle = int(rotate)
    angle %= 360
    if angle not in (0, 90, 180, 270):
        raise ValueError(f"Поворот должен быть 0/90/180/270, получено {angle}")
    return angle


def rotate_frame(frame, angle: int, max_side: int = 0):
    """Повернуть кадр и, если он больше max_side по длинной стороне, уменьшить (4K с телефона → 1920)."""
    if angle:
        frame = cv2.rotate(frame, _ROTATIONS[angle])
    if max_side:
        h, w = frame.shape[:2]
        k = max_side / max(h, w)
        if k < 1:
            frame = cv2.resize(frame, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
    return frame


def is_file(source: str) -> bool:
    return Path(source).exists()


class FileSource:
    def __init__(self, source: str, rotate="auto", max_side: int = 0):
        self.cap = _open(source)
        self.fps = self.cap.get(cv2.CAP_PROP_FPS) or 25.0
        self.rotation = resolve_rotation(self.cap, rotate)
        self.max_side = max_side

    def frames(self) -> Iterator[Frame]:
        idx = 0
        while True:
            ok, frame = self.cap.read()
            if not ok:
                return
            yield idx / self.fps, rotate_frame(frame, self.rotation, self.max_side), 0
            idx += 1

    def latency(self) -> float:
        return 0.0

    def close(self) -> None:
        self.cap.release()


class LiveSource:
    def __init__(self, source: str, loop: bool = False, reconnect_seconds: float = 2.0, rotate="auto",
                 max_side: int = 0):
        self.source = source
        self.file = is_file(source)
        self.loop = loop
        self.reconnect_seconds = reconnect_seconds
        self.cap = _open(source)
        self.fps = self.cap.get(cv2.CAP_PROP_FPS) or 25.0
        self.rotate = rotate
        self.max_side = max_side
        self.rotation = resolve_rotation(self.cap, rotate)
        self._frame: Optional["cv2.Mat"] = None
        self._ts = 0.0
        self._seq = 0
        self._last_ts = 0.0
        self._lock = threading.Condition()
        self._stop = threading.Event()
        self._eof = False
        self.start = time.monotonic()
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()

    # ------------------------------------------------------------ поток чтения
    def _reader(self) -> None:
        period = 1.0 / self.fps
        t0, n = time.monotonic(), 0
        while not self._stop.is_set():
            ok, frame = self.cap.read()
            if not ok:
                if self.file and self.loop:
                    self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                    continue
                if self.file:
                    with self._lock:
                        self._eof = True
                        self._lock.notify_all()
                    return
                # Камера/RTSP отвалилась — переподключаемся
                print(f"[source] поток прервался, переподключение через {self.reconnect_seconds} с", flush=True)
                self.cap.release()
                time.sleep(self.reconnect_seconds)
                try:
                    self.cap = _open(self.source)
                    self.rotation = resolve_rotation(self.cap, self.rotate)
                except RuntimeError:
                    pass
                continue
            frame = rotate_frame(frame, self.rotation, self.max_side)  # до паузы, чтобы не сбивать темп
            n += 1
            if self.file:  # файл отдаём в темпе его fps, как это делала бы камера
                delay = t0 + n * period - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                elif delay < -1.0:  # декодирование отстаёт больше чем на секунду — сбрасываем расписание
                    t0, n = time.monotonic(), 0
            with self._lock:
                self._frame, self._ts, self._seq = frame, time.monotonic(), self._seq + 1
                self._lock.notify_all()

    # ------------------------------------------------------------ API
    def next_frame(self, last_seq: int, timeout: float = 1.0):
        """Ждать кадр новее last_seq. Возвращает (seq, время от старта, кадр) или None, если поток закончился.

        Кадр общий для всех потребителей — рисовать только на копии.
        Несколько потребителей (показ и детекция) читают независимо, каждый со своим last_seq.
        """
        with self._lock:
            while not self._stop.is_set():
                if self._seq != last_seq and self._frame is not None:
                    return self._seq, self._ts - self.start, self._frame
                if self._eof:
                    return None
                self._lock.wait(timeout)
        return None

    def frames(self) -> Iterator[Frame]:
        """Генератор (время, кадр, сколько пропущено) — для одного потребителя."""
        last_seq = 0
        while True:
            r = self.next_frame(last_seq)
            if r is None:
                return
            seq, t, frame = r
            dropped, last_seq = seq - last_seq - 1, seq
            self._last_ts = t + self.start
            yield t, frame, dropped

    def stop(self) -> None:
        with self._lock:
            self._stop.set()
            self._lock.notify_all()

    def latency(self) -> float:
        """Сколько секунд прошло с момента прихода текущего обрабатываемого кадра."""
        return time.monotonic() - self._last_ts if self._last_ts else 0.0

    def close(self) -> None:
        self.stop()
        self._thread.join(timeout=2)
        self.cap.release()
