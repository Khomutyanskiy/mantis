"""Запуск Mantis.

Пакетный анализ файла (каждый кадр, без пропусков):
    python run.py --source video.mp4 --config config.yaml

Живой режим — камера, RTSP или эмуляция камеры из файла, с окном на экране:
    python run.py --source video.mp4 --config config.yaml --live --loop --show --device mps
    python run.py --source rtsp://localhost:8554/cam --config config.yaml --live --show --device mps
    python run.py --source 0 --live --show                      # веб-камера

В окне: q / Esc — выход, пробел — пауза, f — во весь экран.
"""
import argparse
import json

from mantis.config import load_config
from mantis.pipeline import run


def main() -> None:
    ap = argparse.ArgumentParser(description="Mantis — подсчёт прохожих, торможений и взглядов на витрину")
    ap.add_argument("--source", required=True, help="видеофайл, rtsp://... или индекс камеры")
    ap.add_argument("--config", default=None, help="YAML-конфиг (по умолчанию — встроенные значения)")
    ap.add_argument("--live", action="store_true",
                    help="режим живой камеры: реальный темп, пропуск кадров, если не успеваем")
    ap.add_argument("--loop", action="store_true", help="live + файл: крутить файл по кругу, как бесконечный поток")
    ap.add_argument("--show", action="store_true", help="показывать окно с разметкой")
    ap.add_argument("--save-video", action="store_true", help="сохранять размеченное видео (в live по умолчанию выкл.)")
    ap.add_argument("--no-video", action="store_true", help="не сохранять размеченное видео")
    ap.add_argument("--max-frames", type=int, default=None)
    ap.add_argument("--device", default=None, help="cpu / mps (Mac M1+) / 0 (NVIDIA)")
    ap.add_argument("--rotate", default=None, help="поворот кадра: auto / 0 / 90 / 180 / 270")
    ap.add_argument("--fullscreen", action="store_true", help="окно во весь экран (в окне — клавиша f)")
    ap.add_argument("--imgsz", type=int, default=None, help="размер входа сети: 640 / 960 / 1280")
    args = ap.parse_args()

    cfg = load_config(args.config)
    if args.show:
        cfg["output"]["show"] = True
    if args.live:
        cfg["output"]["save_video"] = False
    if args.save_video:
        cfg["output"]["save_video"] = True
    if args.no_video:
        cfg["output"]["save_video"] = False
    if args.device:
        cfg["model"]["device"] = args.device
    if args.rotate is not None:
        cfg["source"]["rotate"] = args.rotate
    if args.fullscreen:
        cfg["output"]["fullscreen"] = True
    if args.imgsz:
        cfg["model"]["imgsz"] = args.imgsz

    report = run(args.source, cfg, args.max_frames, live=args.live, loop=args.loop)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
