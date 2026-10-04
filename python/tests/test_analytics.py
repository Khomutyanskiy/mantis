"""Тесты логики на синтетических траекториях (без нейросети)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mantis.analytics import Analytics, Detection  # noqa: E402
from mantis.config import load_config  # noqa: E402
from mantis.geometry import point_in_polygon, segments_intersect  # noqa: E402
from mantis.headpose import estimate_head_pose, is_looking  # noqa: E402

FPS = 25
H = 200  # рост человека в пикселях


def face_kpts(cx, top, yaw_shift=0.0, back=False):
    """17 точек COCO; yaw_shift сдвигает нос относительно центра головы (в полуширинах)."""
    k = [[0, 0, 0.0] for _ in range(17)]
    half = 20
    k[3] = [cx - half, top + 20, 0.9]                    # левое ухо
    k[4] = [cx + half, top + 20, 0.9]                    # правое ухо
    if not back:
        k[0] = [cx + yaw_shift * half, top + 25, 0.9]   # нос
        k[1] = [cx - 8 + yaw_shift * half, top + 18, 0.9]
        k[2] = [cx + 8 + yaw_shift * half, top + 18, 0.9]
    k[5] = [cx - 40, top + 50, 0.9]
    k[6] = [cx + 40, top + 50, 0.9]
    return k


def make(cfg=None):
    cfg = cfg or load_config(None)
    line = [(500, 0), (500, 1000)]
    zone = [(300, 0), (700, 0), (700, 1000), (300, 1000)]
    return Analytics(cfg, line, zone)


def walk(a, tid, xs, y=600, kp=None, t0=0.0):
    for i, x in enumerate(xs):
        k = kp(x) if kp else None
        a.update(t0 + i / FPS, [Detection(tid, (x - 40, y - H, x + 40, y), k)])


def linspace(a, b, n):
    return [a + (b - a) * i / (n - 1) for i in range(n)]


def test_geometry():
    assert point_in_polygon((5, 5), [(0, 0), (10, 0), (10, 10), (0, 10)])
    assert not point_in_polygon((15, 5), [(0, 0), (10, 0), (10, 10), (0, 10)])
    assert segments_intersect((0, 5), (10, 5), (5, 0), (5, 10))
    assert not segments_intersect((0, 5), (4, 5), (5, 0), (5, 10))


def test_fast_walker_passes_without_slowing():
    a = make()
    # ~1 рост/с: 200 px/с, 4 с через кадр 0..800
    walk(a, 1, linspace(0, 800, 4 * FPS))
    r = a.report()
    assert r["passed"] == 1 and r["passed_forward"] + r["passed_backward"] == 1
    assert r["slowed"] == 0 and r["looked"] == 0


def test_direction():
    a = make()
    walk(a, 1, linspace(0, 800, 100))
    walk(a, 2, linspace(800, 0, 100), t0=10)
    r = a.report()
    assert r["passed"] == 2 and r["passed_forward"] == 1 and r["passed_backward"] == 1


def test_stopper_slows_down():
    a = make()
    xs = linspace(0, 450, 50) + [450] * (2 * FPS) + linspace(450, 900, 50)
    walk(a, 1, xs)
    r = a.report()
    assert r["passed"] == 1 and r["slowed"] == 1


def test_crossing_counted_once_even_if_back_and_forth():
    a = make()
    xs = linspace(400, 600, 20) + linspace(600, 400, 20) + linspace(400, 600, 20)
    walk(a, 1, xs)
    assert a.report()["passed"] == 1


def test_looker_camera_mode():
    a = make()
    xs = linspace(300, 700, 3 * FPS)  # медленный проход по зоне
    walk(a, 1, xs, kp=lambda x: face_kpts(x, 400, yaw_shift=0.1))
    assert a.report()["looked"] == 1


def test_back_to_camera_is_not_looking():
    a = make()
    walk(a, 1, linspace(300, 700, 3 * FPS), kp=lambda x: face_kpts(x, 400, back=True))
    assert a.report()["looked"] == 0


def test_profile_not_looking_in_camera_mode_but_looking_in_side_mode():
    a = make()
    walk(a, 1, linspace(300, 700, 3 * FPS), kp=lambda x: face_kpts(x, 400, yaw_shift=0.9))
    assert a.report()["looked"] == 0

    cfg = load_config(None)
    cfg["look"]["showcase_direction"] = "right"
    a = make(cfg)
    walk(a, 1, linspace(300, 700, 3 * FPS), kp=lambda x: face_kpts(x, 400, yaw_shift=0.9))
    assert a.report()["looked"] == 1


def test_short_glance_not_counted():
    a = make()
    n = 3 * FPS
    xs = linspace(300, 700, n)
    look_frames = range(10, 15)  # 0.2 c
    for i, x in enumerate(xs):
        k = face_kpts(x, 400, yaw_shift=0.0 if i in look_frames else 0.9)
        a.update(i / FPS, [Detection(1, (x - 40, 400, x + 40, 600), k)])
    assert a.report()["looked"] == 0


def test_headpose_values():
    assert abs(estimate_head_pose(face_kpts(100, 0, 0.0)).yaw) < 1e-6
    assert estimate_head_pose(face_kpts(100, 0, 0.6)).yaw > 0.5
    assert not estimate_head_pose(face_kpts(100, 0, back=True)).face_visible
    assert is_looking(estimate_head_pose(face_kpts(100, 0, -0.6)), "left", 0.35, 0.35)


def test_lost_tracks_are_finalized():
    a = make()
    walk(a, 1, linspace(0, 800, 100))
    a.update(100.0, [])
    assert not a.tracks and len(a.finished) == 1 and a.finished[0]["passed"] == 1


def test_live_source_paces_and_drops(tmp_path):
    """LiveSource отдаёт файл в реальном темпе и пропускает кадры, если потребитель медленный."""
    import time

    import cv2
    import numpy as np

    from mantis.source import LiveSource

    path = str(tmp_path / "v.avi")
    w = cv2.VideoWriter(path, cv2.VideoWriter_fourcc(*"MJPG"), 20, (64, 48))
    for i in range(40):  # 2 секунды при 20 fps
        w.write(np.full((48, 64, 3), i * 5, dtype=np.uint8))
    w.release()

    src = LiveSource(path)
    t_start = time.monotonic()
    got, dropped = 0, 0
    for t, frame, d in src.frames():
        got += 1
        dropped += d
        time.sleep(0.1)  # обработка вдвое медленнее потока
    elapsed = time.monotonic() - t_start
    src.close()
    assert 1.7 < elapsed < 3.0          # файл шёл в реальном темпе, а не мгновенно
    assert dropped > 10 and got < 30    # отставшие кадры пропущены, очередь не копилась


def test_walking_towards_camera_is_not_slowing():
    """Идёт прямо на камеру: ноги почти на месте, человек растёт — это не торможение."""
    cfg = load_config(None)
    a = Analytics(cfg, [(500, 0), (500, 1000)], [(0, 0), (1080, 0), (1080, 1920), (0, 1920)], frame_size=(1080, 1920))
    n = 6 * FPS
    for i in range(n):
        h = 150 * (1.25 ** (i / FPS))  # рост рамки ~25% в секунду: подходит к камере обычным шагом
        a.update(i / FPS, [Detection(1, (300 - h * 0.2, 1200 - h, 300 + h * 0.2, 1200), None)])
    assert a.report()["slowed"] == 0


def test_standing_person_is_slowing_with_depth_on():
    cfg = load_config(None)
    a = Analytics(cfg, [(500, 0), (500, 1000)], [(0, 0), (1080, 0), (1080, 1920), (0, 1920)], frame_size=(1080, 1920))
    for i in range(3 * FPS):
        a.update(i / FPS, [Detection(1, (260, 900, 340, 1200), None)])
    assert a.report()["slowed"] == 1


def test_dwell_ignored_for_full_frame_zone():
    cfg = load_config(None)
    cfg["slowdown"]["dwell_seconds"] = 2.0
    full = [(0, 0), (1080, 0), (1080, 1920), (0, 1920)]
    a = Analytics(cfg, [(500, 0), (500, 1000)], full, frame_size=(1080, 1920))
    # идёт по кадру 5 с обычным шагом — долго в «зоне», но зона = весь кадр
    for i in range(5 * FPS):
        x = 100 + 160 * i / FPS
        a.update(i / FPS, [Detection(1, (x - 40, 1000, x + 40, 1200), None)])
    assert a.report()["slowed"] == 0
