# Mantis — аналитика витрины и торгового зала

Считает, сколько людей прошло мимо витрины, притормозило, посмотрело и зашло в магазин — и сколько это в деньгах.
Обычная камера (телефон или IP-камера), нейросеть на устройстве, видео никуда не отправляется.

## Состав

| Папка | Что внутри |
|---|---|
| `mantis/` | iOS-приложение (SwiftUI, Core ML, VideoToolbox): анализ видео, живой режим с камеры телефона и IP-камеры (RTSP, поиск по ONVIF), тепловые карты, оценка витрины, деньги, статистика по часам, PDF-отчёты, профиль и Firebase |
| `python/` | Прототип и эталон аналитики: YOLO11n-pose + ByteTrack, подсчёт из файла и RTSP, тесты, эмулятор камеры `tools/fake_camera.sh` |
| `design/` | Иконка приложения |
| `demo/` | Пример результата прототипа (события, треки, сводка) |
| `Mantis_presentation.pdf` | Презентация системы |

## iOS: сборка

1. Откройте `mantis/mantis.xcodeproj` в Xcode 26+ (iOS 26.1).
2. Добавьте пакет `https://github.com/firebase/firebase-ios-sdk` → `FirebaseAuth`, `FirebaseFirestore` (без него приложение собирается, облако отключено).
3. Положите свой `GoogleService-Info.plist` в `mantis/mantis/` (в репозиторий не входит).
4. В консоли Firebase: Authentication → Email/Password; Firestore с правилами:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{db}/documents {
    match /users/{uid}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == uid;
    }
  }
}
```

## Python-прототип

```bash
cd python
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python run.py --source video.mp4 --config config.example.yaml --show
# эмуляция IP-камеры: ./tools/fake_camera.sh video.mp4 → rtsp://localhost:8554/cam
```

## Приватность

Лица не распознаются и не сохраняются, видео не записывается. В облако уходят только обезличенные цифры: профиль магазина, счётчики по часам, итоги анализов.

© РСМ АйТи
