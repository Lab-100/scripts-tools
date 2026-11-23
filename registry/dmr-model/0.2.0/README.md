# dmr-model — управление моделями Docker Model Runner без `docker model`

Docker Desktop 4.92 (CLI 29.8.0) **не содержит** команды `docker model`, а HTTP-эндпоинты
`/models` у раннера умеют только GET/DELETE (DELETE — удаляет модель, это **не** выгрузка
из памяти). Инструмент работает напрямую с OCI-layout `%USERPROFILE%\.docker\models`
(`models.json`, `manifests`, `blobs`, `bundles`) через Registry API Docker Hub.

## Запуск

```powershell
pwsh -NoProfile -File C:\Scripts\tools\dmr-model.ps1 list                     # установленные модели
pwsh -NoProfile -File C:\Scripts\tools\dmr-model.ps1 verify                   # сверка индексов (код 0 = ок)
pwsh -NoProfile -File C:\Scripts\tools\dmr-model.ps1 install -Repo ai/qwen2.5 -Tag 3B-Q4_K_M
pwsh -NoProfile -File C:\Scripts\tools\dmr-model.ps1 remove  -Id ai/qwen2.5:3B-Q4_K_M
```

Общие параметры: `-Quiet`, `-TimeoutSec <n>`; у `install` есть `-DryRun`.

Переменные окружения: `INVR_DMR_STORE` (по умолчанию `%USERPROFILE%\.docker\models`),
`INVR_DMR_ENDPOINT` (по умолчанию `http://127.0.0.1:12434`).

## Важно

- **`remove` необратим** для блобов: GGUF-файл модели удаляется с диска. Прежде чем
  удалять — убедись, что модель не нужна; тяжёлые файлы качаются заново неделями.
- **Не запускай `remove` на модели, которую держит раннер**: файл открыт, индекс
  разойдётся с диском. Сначала дождись выгрузки (процесс `com.docker.llama-server`
  завершён) или перезапусти Docker Desktop.
- **Повторный `install` уже установленной модели** не пересоздаёт занятый hardlink —
  если файл удерживается раннером, будет понятная ошибка вместо `Access denied`.
- Проверять целостность после любых манипуляций: `verify` (код 0 = ок).
- Тяжёлые `*.pack` и блобы не коммитятся в каталог отката (лимит GitHub 100 МБ).

## Хранилище

`%USERPROFILE%\.docker\models\` — `models.json` (индекс), `manifests\` (JSON-манифесты),
`blobs\sha256\` (сами веса), `bundles\sha256\` (распакованные GGUF для раннера),
`layout.json`. Модель в `/v1/models` видна только после записи в `models.json`.
