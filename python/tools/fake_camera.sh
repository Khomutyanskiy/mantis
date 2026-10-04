#!/usr/bin/env bash
# Эмуляция IP-камеры: отдаёт видеофайл как RTSP-поток rtsp://localhost:8554/cam в реальном темпе, по кругу.
#
#   brew install mediamtx ffmpeg        # один раз
#   ./tools/fake_camera.sh ../IMG_1761.MOV
#   # в другом терминале:
#   python run.py --source rtsp://localhost:8554/cam --config config.img1761.yaml --live --show --device mps
#
# Ctrl+C — остановить.
set -euo pipefail

VIDEO="${1:?Укажите видеофайл: ./tools/fake_camera.sh video.mp4}"
URL="${2:-rtsp://localhost:8554/cam}"
HEIGHT="${HEIGHT:-1280}"   # высота кадра потока; 4K с телефона ужимаем, иначе тормозит декодирование

command -v mediamtx >/dev/null || { echo "Нет mediamtx: brew install mediamtx"; exit 1; }
command -v ffmpeg  >/dev/null || { echo "Нет ffmpeg: brew install ffmpeg"; exit 1; }

mediamtx >/tmp/mediamtx.log 2>&1 &
MTX_PID=$!
trap 'kill $MTX_PID 2>/dev/null' EXIT
sleep 1

echo "Камера: $URL  (видео: $VIDEO)"
ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i "$VIDEO" \
  -vf "scale=-2:${HEIGHT}" -an -c:v libx264 -preset veryfast -tune zerolatency -g 30 \
  -f rtsp -rtsp_transport tcp "$URL"
