# Архитектурный анализ dual-mode запуска ANPR (embedded + standalone)

## A. Краткий verdict

1. Целевая архитектура уже читается в текущем коде как **общий ANPR runtime + опциональные web adapters**: распознавание и orchestration сосредоточены в `packages/anpr_core.ChannelProcessor` и `anpr.pipeline`, а SSE/MJPEG/API — в `app/api/routers/*`.
2. Задача dual-mode достижима **без большого редизайна**: основная логика обработки кадров уже не зависит от FastAPI напрямую; нужен отдельный bootstrap для standalone, который переиспользует `ChannelProcessor` и `SettingsManager`.
3. Главный узкий момент: `ChannelProcessor` сейчас смешивает runtime и delivery concerns (генерация preview JPEG, callback в web event bus, прямой вызов controller automation через API container) — это нужно сделать опциональными sink/adapter-слоями.
4. Для standalone не требуется «убирать web»; требуется отделить запуск ANPR-контура от web lifecycle (`AppContainer.startup/shutdown`) и сделать feature flags/опции для preview/SSE.

## B. Таблица компонентов

| Компонент | Где сейчас | Логический слой | Нужен в embedded mode | Нужен в standalone mode | Комментарий / почему |
|---|---|---|---|---|---|
| source/video ingestion | `packages/anpr_core/channel_runtime.py` (`_open_capture`, `_configure_capture_timeouts`, `_reopen_capture`) | runtime orchestration | Да | Да | Базовая функция контура, не web-specific. |
| frame loop | `packages/anpr_core/channel_runtime.py` (`_run_channel` while-loop) | runtime orchestration | Да | Да | Центральный execution loop для channel isolation и reconnection. |
| ROI mask / ROI filtering | `packages/anpr_core/channel_runtime.py` (`_apply_roi_mask`, `_filter_detections_by_roi`) | runtime stage (pre/post detection) | Да | Да | ROI применяется до детектора и при фильтрации bbox, это processing-stage, не UI. |
| motion gate | `packages/anpr_core/channel_runtime.py` + `anpr/detection/motion_detector.py` | runtime stage | Да | Да | Управляет пропуском инференса по движению. |
| detector stride | `packages/anpr_core/channel_runtime.py` (`detector_frame_stride`) | runtime stage | Да | Да | Оптимизация нагрузки inference; должна работать в обоих режимах. |
| detection | `anpr/detection/yolo_detector.py`, вызов из `ChannelProcessor` | domain/runtime boundary | Да | Да | Core detection путь, общий. |
| OCR | `anpr/recognition/*`, `anpr/pipeline/anpr_pipeline.py` | domain/core | Да | Да | Core распознавание номеров. |
| track aggregation / consensus | `anpr/pipeline/anpr_pipeline.py` (`TrackAggregator`) | domain/core | Да | Да | Влияет на итоговый plate consensus, не связан с web. |
| validation / postprocessing | `anpr/postprocessing/*`, `ANPRPipeline.process_frame` | domain/core | Да | Да | Нормализация/валидация номера. |
| cooldown | `ANPRPipeline._on_cooldown/_touch_plate` | runtime/business rule | Да | Да | Дедупликация событий по времени для обоих запусков. |
| list filtering | `controllers/service.py` (`_resolve_channel_controller_action`) + `database/plate_lists_repository.py` | adapter/application policy | Да (если включена автоматика) | Опционально | Это не OCR core; это policy для внешнего действия (relay). |
| event persistence | `packages/anpr_core/event_sink.py` -> `database/postgres_event_repository.py` | runtime output adapter | Да | Да | Обычно общий sink, PostgreSQL-only уже соблюден. |
| event publication | callback `event_callback` в `ChannelProcessor`; `AppContainer.publish_event_sync` | runtime output adapter | Да | Да (в другой sink) | В embedded идет в in-memory bus + controller automation; в standalone может идти в другой publisher или noop. |
| preview JPEG / MJPEG | JPEG в `ChannelProcessor` (`cv2.imencode`, `latest_jpeg`), MJPEG в `app/api/routers/channels.py` | web adapter / delivery | Да (опционально) | Нет (опционально) | Это browser delivery слой, не часть ANPR core. |
| SSE / browser updates | `packages/anpr_core/event_bus.py`, `app/api/routers/events.py` (`/api/events/stream`) | web adapter | Да | Нет (опционально) | Нужен только для web realtime UI. |
| API роуты | `app/api/routers/*` | web/API adapter | Да | Нет | HTTP contract для web клиента. |
| channel lifecycle / start-stop / restart | `ChannelProcessor.start/stop/restart`, orchestration через `AppContainer` и `channels router` | runtime orchestration + web control adapter | Да | Да | Runtime методы уже reusable; web только триггерит их через API. |

## C. Отдельный verdict по ROI

- ROI по факту текущего кода — это **runtime-stage кадра** (preprocessing + post-detection filtering), а не browser/UI-функция.
- ROI должен быть общим для embedded и standalone режимов, т.к. влияет на вход детектора и итоговые detections до OCR.
- Перенос ROI под границу `anpr` возможен, но не обязателен в low-level OCR pipeline: логичнее держать его в runtime/application слое frame-processing (например, внутри reusable stage-модуля `packages/anpr_core`), где уже живут motion gate и detector stride.
- Следовательно: ROI не web-adapter; web только редактирует конфиг ROI через API/settings.

## D. Конкретные файлы/модули

### Оставить как есть
- `anpr/pipeline/anpr_pipeline.py` — core последовательность OCR/consensus/postprocess/cooldown.
- `anpr/pipeline/factory.py` — сборка detector+recognizer+pipeline с shared OCR singleton.
- `anpr/detection/*`, `anpr/recognition/*`, `anpr/postprocessing/*` — domain компоненты.
- `database/postgres_event_repository.py` и `database/plate_lists_repository.py` — PostgreSQL backend слой.

### Декомпозировать
- `packages/anpr_core/channel_runtime.py`:
  - выделить опциональные output hooks: `preview_sink`, `event_sink`, `event_publisher`;
  - оставить внутри общий frame loop/reconnect/motion/stride/ROI.
- `app/api/container.py`:
  - разделить bootstrap runtime и web adapters (сейчас container создаёт всё в одном месте).

### Отвязать от web-specific зависимостей
- Связку `ChannelProcessor -> event_callback -> AppContainer.publish_event_sync` сделать через абстракцию publisher/sink, чтобы standalone мог подключить другой обработчик (или noop) без FastAPI loop.
- Preview-путь (`latest_jpeg`, `preview_ready`) сделать отключаемым флагом (например, `preview_enabled`) чтобы ANPR запускался без MJPEG.
- Controller automation (`ControllerAutomationService`) оставить adapter-слоем «реакции на события», не обязательной частью runtime.

### Не трогать
- `app/api/routers/*` как web facade (кроме подключения к новому bootstrap/runtime facade).
- `app/web/*` (UI слой), т.к. dual-mode цель не требует изменений браузерной части.

## E. Минимальный план подготовки к dual-mode запуску

1. Ввести runtime bootstrap модуль (например, `app/runtime/bootstrap.py`), который создаёт `SettingsManager`, `ChannelProcessor`, persistence sink и запускает каналы — без FastAPI-специфики.
2. В `ChannelProcessor` формализовать опциональные adapters:
   - event publish adapter,
   - preview adapter (вкл/выкл),
   - optional automation hook.
3. Переключить `AppContainer` на использование runtime bootstrap вместо прямой сборки runtime внутри web container.
4. Добавить standalone entrypoint (служба/daemon), который использует тот же bootstrap, но без mount web/static/router и без обязательного SSE/MJPEG.
5. Оставить единый settings source (`config/settings.yaml`) для обоих режимов, чтобы не дублировать конфиг канала/ROI/motion/stride.
6. Добавить smoke-check сценарии:
   - embedded: события + preview + SSE;
   - standalone: события и persistence при отключённом preview/SSE.

## F. Риски и регрессии

- Preview: при выносе preview в optional adapter можно случайно сломать `snapshot.jpg`/`preview.mjpg` (пустые кадры, stale timestamps).
- Startup/shutdown: риск двойного старта channel threads при одновременном runtime bootstrap и web startup hooks.
- Event delivery: если publisher abstraction сделан неверно, можно потерять события между runtime и SSE/automation.
- Controller automation: изменение точки вызова `dispatch_event` может нарушить list filtering semantics.
- Persistence: при разделении sink/publisher важно сохранить текущий порядок `insert_event -> publish/dispatch`, иначе UI/автоматика увидят несогласованность.
- Threading/lifecycle: `ChannelProcessor` использует threads + shared recognizer init; нужно аккуратно сохранить thread-safe инициализацию OCR singleton и завершение потоков.

---

## Вывод по целевой модели

Корректная цель — **не standalone вместо web**, а **общий ANPR runtime + опциональные adapters для web delivery**. MJPEG preview, SSE и browser updates должны быть съемными слоями поверх общего runtime. ROI/motion gate/detector stride/frame loop должны оставаться общими и работать в обоих режимах запуска.
