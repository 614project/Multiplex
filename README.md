# Multiplex

Multiplex batches Stable Diffusion txt2img requests across many prompt cells. Each project keeps shared
generation settings, each cell adds its own prompt and optional overrides, and one press of **Generate**
runs every cell (or only the selected ones) against a Stable Diffusion WebUI (A1111) or ComfyUI server.

It is a Flutter / Material 3 rebuild of the Windows-only
[WebuiMultiflex](https://github.com/614project/WebuiMultiflex). The generation engine is a direct port, and it
runs on Windows, macOS, Linux, Android and iOS. The desktop layout follows the original app. Phones get their
own design.

![Desktop workspace](docs/screenshots/desktop-workspace.png)

## Features

- Multiple projects, each with its own server, platform, prompts, sampling, checkpoint, LoRAs and Hires.fix.
- Prompt cells with per-cell overrides for steps, CFG, size, seed and negative prompt, and drag-to-reorder.
- Round-robin repeat: every selected cell is generated once per round until the repeat count is used up.
- A FIFO job queue. Generate and Regenerate keep adding jobs while one is running, and waiting jobs can be
  reordered or removed.
- A two-stage interrupt. The first press stops after the image already requested, and the second
  force-stops the current job. Work left on the server is then cleaned up (queued ComfyUI prompts,
  Agent Scheduler tasks, a timed-out WebUI request).
- WebUI generation modes: `Standard`, `Polling (Proxy Safe)` and `Agent Scheduler`. ComfyUI uses a
  built-in txt2img workflow, so no workflow JSON is needed.
- Live previews and progress in the header, the project list and the mobile dock.
- Cell detail page with the image history, a representative image, PNG metadata inspection (WebUI infotext
  and ComfyUI prompt graph), and a **Versus** tournament to pick the best of several images.
- Prompt autocomplete from Danbooru tag lists, plus your own CSV.
- JSON import and export of single projects and multi-project bundles, compatible with WebuiMultiflex files.
- Collect: copy each cell's shown image as a PNG with metadata, a PNG without metadata, or a JPEG.
- Material 3 theming with light and dark modes, a choice of seed colors, and wallpaper-based dynamic color
  where the platform supports it.

## Two layouts

Multiplex picks a layout from the window width rather than the platform, so a narrow desktop window gets the
phone layout and a tablet in landscape gets the desktop one.

| Width | Layout |
| --- | --- |
| < 600 dp | Phone: bottom navigation bar and a generation dock |
| 600–840 dp | Phone layout with a navigation rail |
| ≥ 840 dp | Desktop: collapsible project pane and a tabbed workspace |

### Desktop and tablet

- A collapsible project pane with live progress for every project.
- The workspace has **Cells**, **Settings** and **Queue** tabs. Cells can be shown as a list or as large
  icons.
- **Stop**, **Generate**, the repeat stepper and the project menu sit together in the header. The stepper
  and menu don't move when a job starts.
- In the cell detail page, click to select an image, Ctrl/⌘-click to add one, and Shift-click to select a
  range. The check button that appears on hover selects images without a keyboard. Arrow keys step through
  images, `Delete` removes the selection, and `Ctrl+A` selects all.
- Keyboard shortcuts: `Ctrl+Enter` generates and `Ctrl+S` saves. In Versus, `←`/`1` and `→`/`2` pick a
  side and `Esc` goes back.

![Cell detail page](docs/screenshots/desktop-cell-detail.png)

### Phone

The phone layout is built for one hand. It doesn't shrink the desktop screens:

- **Cells** is a two-column gallery of image cards (it can switch to one column). The cell name and its
  overrides are shown on the image. Tap a card to open its images (a cell without images opens the editor),
  or long-press to start selecting cells. Pull down to check the server connection again.
- A **generation dock** sits above the navigation bar. When idle it shows the repeat stepper and Generate
  button. While a job runs it becomes a mini player with the live preview, the progress, a button to queue
  another run, and Stop.
- **Setup** holds the project settings as collapsible cards. Each card shows a one-line summary, so you
  don't have to expand everything to check a value.
- The **cell editor** is a bottom sheet. It includes tag suggestion chips and a preview of the exact prompt
  and parameters that will be sent.
- The **image viewer** is full screen: swipe between images, pinch to zoom, and use the thumbnail strip.
  Its action bar has Details, Save to gallery, Share, Generate again and Delete. A selection mode supports
  multi-select, Versus, save and share.
- Switch, create and import projects from the title in the app bar.

![Phone layout](docs/screenshots/mobile.png)

## Server setup

- **WebUI (A1111 / Forge)**: start it with `--api`. Add `--listen` if the app runs on another device (a phone,
  for example).
- **ComfyUI**: start it with `--listen` if the app runs on another device.
- **Agent Scheduler** mode needs the
  [sd-webui-agent-scheduler](https://github.com/ArtVentureX/sd-webui-agent-scheduler) extension.

How the server address is chosen: the project's API base URL is used if set. Otherwise the global URL
from the app settings is used, and if that is empty too, the platform default (`http://127.0.0.1:7860`
for WebUI, `http://127.0.0.1:8188` for ComfyUI). URLs of the form `http://user:password@host:port` are sent
as HTTP Basic authentication. A URL copied with `/docs`, `/sdapi/v1` or `/agent-scheduler/v1` at the end is
also accepted.

The app allows plain `http://` traffic to LAN servers on Android and iOS. Credentials are never written to
exported JSON.

### API usage

WebUI:
- `POST /sdapi/v1/txt2img`
- `GET /sdapi/v1/progress` and `POST /internal/progress`, for live previews and proxy-safe recovery
- `POST /sdapi/v1/interrupt`
- The Agent Scheduler queue, task and result endpoints
- LoRAs are appended as `<lora:name:weight>`. The checkpoint and CLIP skip are sent in `override_settings`.

ComfyUI:
- `/object_info` lists checkpoints, samplers, schedulers, latent upscale methods and LoRA loaders. The
  metadata is cached per address for 7 days and fetched once per job.
- Generation goes through `/prompt`, then `/history/{id}`, then `/view`. LoRAs are chained through
  `LoraLoader` or `LoraLoaderModelOnly`, and CLIP skip uses `CLIPSetLastLayer`.

## Prompt composition

- The positive prompt is the global addition from the app settings, then the project prompt, then the cell
  prompt.
- If the project prompt contains `<CELL_PROMPT>`, the cell prompt is inserted there instead of being
  appended.
- The negative prompt is the global addition, then the project negative prompt, then the cell's negative
  override.
- Segments are joined with comma-aware normalization, so duplicated or missing commas are cleaned up.
- The cell editor shows the final prompt and parameters before you generate.

## Migrating from WebuiMultiflex

1. In WebuiMultiflex, choose **Export** (one project) or **Export all** (a bundle).
2. In Multiplex, choose **Import** in the project pane (desktop) or the project switcher (phone).

Both the `WebuiMultiflex.Project` and `WebuiMultiflex.ProjectBundle` formats (PascalCase keys) are read.
Multiplex exports the same shape under the `Multiplex.*` format names. Generated images aren't part of the
JSON, so copy them yourself if you need them.

Differences from the original:

- Storage is per-project JSON files (`project.json`) instead of SQLite. Writes are atomic (a temporary file is
  written, then renamed) and ordered per project, so an older snapshot never overwrites newer changes.
- Collect writes PNG or JPEG. WebP output was dropped because the Dart image encoder can't write WebP.
- Importing by dropping a JSON file on the window isn't supported yet. Use the Import button.
- The Windows backdrop (Mica) setting is gone. Material 3 seed colors and dynamic color replace it.

## Data layout

The data root is the platform's application support folder, or `MULTIPLEX_DATA_DIR` if that is set:

| Platform | Default location |
| --- | --- |
| Windows | `%APPDATA%\io.github.project614\Multiplex` |
| macOS | `~/Library/Containers/io.github.project614.multiplex/Data/Library/Application Support/io.github.project614.multiplex` |
| Linux | `~/.local/share/io.github.project614.multiplex` |
| Android / iOS | The app's private support directory |

```
<root>/preferences.json
<root>/comfy-metadata-cache.json
<root>/projects/<project-id>/project.json
<root>/projects/<project-id>/cells/<cell-id>/<yyyyMMdd_HHmmssfff>.png
<root>/prompt-autocomplete/{danbooru,extra-quality-tags,custom-tags}.csv
<root>/logs/multiplex.log
```

Image paths are stored relative to the project folder. Imported paths that point outside it are dropped.

## Building

This needs Flutter 3.47 (Dart 3.13) or newer.

```sh
flutter pub get
flutter run                     # the current desktop, or a connected device
flutter build windows --release
flutter build macos --release
flutter build linux --release   # needs clang, cmake, ninja-build, pkg-config and libgtk-3-dev
flutter build apk --release
flutter build ios --release
```

`dynamic_color` is pinned to 1.x. The 2.x line depends on the separate `material_ui` package, whose
`ColorScheme` type doesn't match Flutter's own yet.

## Tests

```sh
flutter analyze
flutter test
```

The suite covers the pure helpers (prompt composition, URL and path safety, option lists), the API client
(against recorded responses), the generation engine, persistence, PNG metadata, import/export, autocomplete,
and widget tests for both layouts. The engine tests run against an in-process fake server that imitates
WebUI, Agent Scheduler and ComfyUI (`test/support/fake_sd_server.dart`). It can also simulate a proxy dropping
the final txt2img response, and slow or timed-out generations.

### Trying the app without a GPU

The same fake server can run as a real HTTP server, so you can click through the whole app:

```sh
dart run tool/fake_sd_server.dart 7860          # WebUI-style API on port 7860
dart run tool/fake_sd_server.dart 8188 2500 512 # port, milliseconds per image, image size
```

It answers both the WebUI and ComfyUI APIs and returns generated landscape images with real PNG metadata.

## Project structure

```
lib/src/
  models/       settings, project and cell data, preferences, image metadata
  core/         UI-independent helpers (prompt composer, URL/path safety, cancellation, option lists)
  api/          WebUI / Agent Scheduler / ComfyUI client and the built-in ComfyUI workflow
  services/     storage, import/export, PNG metadata reader, autocomplete, image export, logging
  generation/   the job runner (standard, polling, Agent Scheduler and ComfyUI loops, recovery, cleanup)
  state/        AppState, ProjectSession (queue, autosave, server metadata), cell and gallery models
  ui/           theme, shared widgets, desktop shell, mobile shell, cell detail, versus, settings
```

## Troubleshooting

1. If generation fails immediately, check that the selected platform matches the server at the effective
   API URL. The status chip or connection sheet shows which URL is used and whether the server answered.
2. If WebUI answers with 404, it was started without `--api`.
3. If a phone can't connect, start the server with `--listen`, use the computer's LAN IP address (not
   `127.0.0.1`), and on iOS allow local network access.
4. Behind a reverse proxy that cuts long requests, switch the project to `Polling (Proxy Safe)`. A dropped
   final response is then recovered from the progress preview.
5. If ComfyUI lists are empty, open `/object_info` on the server and check that the built-in nodes are
   exposed.
6. For anything unexpected, check `logs/multiplex.log` in the data root.

## Credits

The UI font is [Outfit](https://github.com/Outfitio/Outfit-Fonts), under the SIL Open Font License
(`assets/fonts/OFL.txt`). Tag lists for autocomplete are downloaded on first use from
[tagcomplete](https://github.com/dreamscapeai/tagcomplete).
