import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// An in-memory imitation of Stable Diffusion WebUI (with the Agent Scheduler extension) and ComfyUI.
/// It is used by the engine tests through `MockClient` and by `tool/fake_sd_server.dart` over real HTTP.
class FakeSdServer {
  FakeSdServer({
    this.generationTime = const Duration(milliseconds: 120),
    this.imageSize = 64,
    this.dropFinalGenerationResponse = false,
  });

  final Duration generationTime;
  final int imageSize;

  /// Simulates a reverse proxy that answers 504 although WebUI finished the image.
  bool dropFinalGenerationResponse;

  final List<String> log = [];
  final List<Map<String, Object?>> txt2imgRequests = [];
  final List<Map<String, Object?>> img2imgRequests = [];
  final List<Map<String, Object?>> comfyPrompts = [];

  /// Files uploaded to ComfyUI's input folder through `/upload/image`.
  final Map<String, Uint8List> comfyInputs = {};
  int interruptCount = 0;

  // WebUI state
  _Task? _activeWebUiTask;
  int _previewId = 0;

  // Agent Scheduler state
  final Map<String, _Task> _agentTasks = {};
  final List<String> _agentQueue = [];
  bool _agentWorkerRunning = false;

  // ComfyUI state
  final Map<String, _Task> _comfyTasks = {};
  final List<String> _comfyQueue = [];
  final Map<String, Uint8List> _comfyFiles = {};
  bool _comfyWorkerRunning = false;
  String? _comfyRunning;

  static const checkpoints = ['fake-model-v1.safetensors', 'fake-model-xl.safetensors'];
  static const loras = ['style-a', 'detail-tweaker'];

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    log.add('${request.method} $path');
    if ((request.headers['content-type'] ?? '').startsWith('multipart/form-data')) {
      return path == '/upload/image' ? _uploadImage(request) : _json({'detail': 'Not Found'}, 404);
    }

    final body = request.body.isEmpty ? null : jsonDecode(request.body);
    switch ((request.method, path)) {
      // --- WebUI -----------------------------------------------------------------------------
      case ('GET', '/sdapi/v1/options'):
        return _json({'sd_model_checkpoint': checkpoints.first, 'CLIP_stop_at_last_layers': 1});
      case ('GET', '/sdapi/v1/samplers'):
        return _json([
          for (final name in ['Euler a', 'Euler', 'DPM++ 2M', 'DPM++ SDE']) {'name': name, 'aliases': <String>[]},
        ]);
      case ('GET', '/sdapi/v1/schedulers'):
        return _json([
          for (final name in ['automatic', 'karras', 'exponential']) {'name': name, 'label': _title(name)},
        ]);
      case ('GET', '/sdapi/v1/sd-models'):
        return _json([
          for (final name in checkpoints) {'title': name, 'model_name': name.split('.').first},
        ]);
      case ('GET', '/sdapi/v1/loras'):
        return _json([
          for (final name in loras) {'name': name, 'alias': name},
        ]);
      case ('GET', '/sdapi/v1/upscalers'):
        return _json([
          {'name': 'None'},
          {'name': 'R-ESRGAN 4x+'},
        ]);
      case ('GET', '/sdapi/v1/latent-upscale-modes'):
        return _json([
          {'name': 'Latent'},
          {'name': 'Latent (nearest-exact)'},
        ]);
      case ('POST', '/sdapi/v1/txt2img'):
        return _generate(body! as Map<String, Object?>, txt2imgRequests);
      case ('POST', '/sdapi/v1/img2img'):
        return _generate(body! as Map<String, Object?>, img2imgRequests);
      case ('GET', '/sdapi/v1/progress'):
        return _classicProgress(request.url.queryParameters['skip_current_image'] != 'true');
      case ('POST', '/internal/progress'):
        return _internalProgress(body! as Map<String, Object?>);
      case ('POST', '/sdapi/v1/interrupt'):
        interruptCount++;
        _activeWebUiTask?.interrupted = true;
        return _json({});
      case ('GET', '/openapi.json'):
        return _json({
          'paths': {
            '/sdapi/v1/txt2img': {},
            '/agent-scheduler/v1/queue/txt2img': {},
            '/agent-scheduler/v1/queue/img2img': {},
            '/agent-scheduler/v1/results/{id}': {},
          },
        });
      // --- Agent Scheduler ----------------------------------------------------------------------
      case ('POST', '/agent-scheduler/v1/queue/txt2img' || '/agent-scheduler/v1/queue/img2img'):
        final taskId = 'agent-${_agentTasks.length + 1}';
        final requestJson = body! as Map<String, Object?>;
        (path.endsWith('img2img') ? img2imgRequests : txt2imgRequests).add(requestJson);
        _agentTasks[taskId] = _Task(taskId, requestJson);
        _agentQueue.add(taskId);
        unawaited(_runAgentWorker());
        return _json({'task_id': taskId});
      case ('GET', final p) when p.startsWith('/agent-scheduler/v1/results/'):
        final task = _agentTasks[p.split('/').last];
        if (task == null || task.image == null) {
          return _json({'detail': 'Task not finished'}, 404);
        }

        return _json({
          'success': true,
          'data': [
            {'image': 'data:image/png;base64,${base64.encode(task.image!)}', 'infotext': ''},
          ],
        });
      case ('GET', final p) when p.startsWith('/agent-scheduler/v1/task/'):
        final task = _agentTasks[p.split('/').last];
        return task == null ? _json({'detail': 'Not Found'}, 404) : _json({'id': task.id, 'status': task.status});
      case ('POST', final p) when p.startsWith('/agent-scheduler/v1/task/') && p.endsWith('/delete'):
        final id = p.split('/')[4];
        _agentQueue.remove(id);
        _agentTasks[id]?.status = 'interrupted';
        return _json({'success': true});
      // --- ComfyUI ------------------------------------------------------------------------------
      case ('GET', '/system_stats'):
        return _json({
          'system': {'comfyui_version': '0.3.99-fake'},
          'devices': [
            {'name': 'Fake GPU'},
          ],
        });
      case ('GET', '/object_info'):
        return _json(_objectInfo());
      case ('POST', '/prompt'):
        final payload = body! as Map<String, Object?>;
        final promptId = (payload['prompt_id'] as String?) ?? 'comfy-${_comfyTasks.length + 1}';
        final graph = payload['prompt']! as Map<String, Object?>;
        for (final node in graph.values.cast<Map<String, Object?>>()) {
          final image = (node['inputs']! as Map<String, Object?>)['image'];
          if (node['class_type'] == 'LoadImage' && !comfyInputs.containsKey(image)) {
            return _json({
              'error': {
                'type': 'prompt_outputs_failed_validation',
                'message': 'Prompt outputs failed validation',
                'details': '',
              },
              'node_errors': {
                'LoadImage': {
                  'errors': [
                    {'message': 'Invalid image file', 'details': 'image: $image'},
                  ],
                  'class_type': 'LoadImage',
                },
              },
            }, 400);
          }
        }

        comfyPrompts.add(graph);
        _comfyTasks[promptId] = _Task(promptId, graph);
        _comfyQueue.add(promptId);
        unawaited(_runComfyWorker());
        return _json({'prompt_id': promptId, 'number': _comfyTasks.length, 'node_errors': {}});
      case ('GET', final p) when p.startsWith('/history/'):
        final id = p.substring('/history/'.length);
        final task = _comfyTasks[id];
        if (task == null || task.status == 'pending' || task.status == 'running') {
          return _json({});
        }

        if (task.status == 'interrupted') {
          return _json({
            id: {
              'outputs': {},
              'status': {
                'status_str': 'error',
                'completed': false,
                'messages': [
                  [
                    'execution_interrupted',
                    {'prompt_id': id},
                  ],
                ],
              },
            },
          });
        }

        return _json({
          id: {
            'outputs': {
              '11': {
                'images': [
                  {'filename': '$id.png', 'subfolder': '', 'type': 'output'},
                ],
              },
            },
            'status': {'status_str': 'success', 'completed': true, 'messages': []},
          },
        });
      case ('GET', '/view'):
        final bytes = _comfyFiles[request.url.queryParameters['filename']];
        return bytes == null ? _json({'error': 'not found'}, 404) : http.Response.bytes(bytes, 200);
      case ('GET', '/queue'):
        return _json({
          'queue_running': [
            if (_comfyRunning != null) [0, _comfyRunning, {}, {}, []],
          ],
          'queue_pending': [
            for (final id in _comfyQueue) [1, id, {}, {}, []],
          ],
        });
      case ('POST', '/queue'):
        final delete = ((body! as Map<String, Object?>)['delete'] as List?)?.cast<String>() ?? const [];
        for (final id in delete) {
          if (_comfyQueue.remove(id)) {
            _comfyTasks[id]?.status = 'interrupted';
          }
        }

        return _json({});
      case ('POST', '/interrupt'):
        interruptCount++;
        final running = _comfyRunning;
        if (running != null) {
          _comfyTasks[running]?.interrupted = true;
        }

        return _json({});
    }

    return _json({'detail': 'Not Found'}, 404);
  }

  // --- WebUI ---------------------------------------------------------------------------------------

  /// txt2img or img2img (the request carries `init_images`).
  Future<http.Response> _generate(Map<String, Object?> request, List<Map<String, Object?>> record) async {
    record.add(request);
    final task = _Task('webui', request)..status = 'running';
    task.taskId = request['force_task_id'] as String?;
    _activeWebUiTask = task;
    await _simulate(task);
    task.image = _renderWebUiImage(request);
    task.status = 'done';
    if (identical(_activeWebUiTask, task)) {
      Timer(const Duration(milliseconds: 400), () {
        if (identical(_activeWebUiTask, task)) {
          _activeWebUiTask = null;
        }
      });
    }

    if (dropFinalGenerationResponse) {
      return http.Response('<html>504 Gateway Time-out</html>', 504, reasonPhrase: 'Gateway Timeout');
    }

    return _json({
      'images': [base64.encode(task.image!)],
      'info': '{}',
    });
  }

  http.Response _classicProgress(bool includeImage) {
    final task = _activeWebUiTask;
    if (task == null || task.status == 'done') {
      return _json({
        'progress': 0.0,
        'eta_relative': 0.0,
        'state': {'job_count': 0, 'job_no': 0, 'job': ''},
        'current_image': includeImage && task?.image != null ? base64.encode(task!.image!) : null,
      });
    }

    return _json({
      'progress': task.progress,
      'eta_relative': 1.0,
      'state': {'job_count': 1, 'job_no': 0, 'job': 'txt2img'},
      'current_image': includeImage ? base64.encode(_preview(task)) : null,
    });
  }

  http.Response _internalProgress(Map<String, Object?> request) {
    final taskId = request['id_task'] as String?;
    final task = _activeWebUiTask?.taskId == taskId
        ? _activeWebUiTask
        : _agentTasks.values
              .where((candidate) => candidate.request['force_task_id'] == taskId || candidate.id == taskId)
              .firstOrNull;
    if (task == null) {
      return _json({'active': false, 'queued': false, 'completed': false, 'progress': null, 'eta': null});
    }

    final completed = task.status == 'done';
    final wantsPreview = request['live_preview'] == true && task.status == 'running';
    _previewId++;
    return _json({
      'active': task.status == 'running',
      'queued': task.status == 'pending',
      'completed': completed,
      'progress': completed ? 1.0 : task.progress,
      'eta': 1.0,
      'live_preview': wantsPreview ? 'data:image/png;base64,${base64.encode(_preview(task))}' : null,
      'id_live_preview': wantsPreview ? _previewId : -1,
      'textinfo': null,
    });
  }

  Future<void> _runAgentWorker() async {
    if (_agentWorkerRunning) {
      return;
    }

    _agentWorkerRunning = true;
    try {
      while (_agentQueue.isNotEmpty) {
        final task = _agentTasks[_agentQueue.removeAt(0)]!;
        if (task.status != 'pending') {
          continue;
        }

        task.status = 'running';
        await _simulate(task);
        task.image = _renderWebUiImage(task.request);
        task.status = 'done';
      }
    } finally {
      _agentWorkerRunning = false;
    }
  }

  // --- ComfyUI -------------------------------------------------------------------------------------

  Future<void> _runComfyWorker() async {
    if (_comfyWorkerRunning) {
      return;
    }

    _comfyWorkerRunning = true;
    try {
      while (_comfyQueue.isNotEmpty) {
        final id = _comfyQueue.removeAt(0);
        final task = _comfyTasks[id]!;
        if (task.status != 'pending') {
          continue;
        }

        _comfyRunning = id;
        task.status = 'running';
        await _simulate(task);
        _comfyRunning = null;
        if (task.interrupted) {
          task.status = 'interrupted';
          continue;
        }

        _comfyFiles['$id.png'] = _renderComfyImage(task.request);
        task.status = 'done';
      }
    } finally {
      _comfyWorkerRunning = false;
    }
  }

  Map<String, Object?> _objectInfo() => {
    'CheckpointLoaderSimple': {
      'input': {
        'required': {
          'ckpt_name': [checkpoints, {}],
        },
      },
    },
    'KSampler': {
      'input': {
        'required': {
          'sampler_name': [
            ['euler', 'euler_ancestral', 'dpmpp_2m'],
            {},
          ],
          'scheduler': [
            ['normal', 'karras', 'simple'],
            {},
          ],
        },
      },
    },
    'LatentUpscaleBy': {
      'input': {
        'required': {
          'upscale_method': [
            ['nearest-exact', 'bislerp'],
            {},
          ],
        },
      },
    },
    'LoraLoader': {
      'input': {
        'required': {
          'lora_name': [
            'COMBO',
            {'options': loras.map((name) => '$name.safetensors').toList()},
          ],
        },
      },
    },
    'CLIPSetLastLayer': {
      'input': {'required': {}},
    },
    'ImageScale': {
      'input': {
        'required': {
          'upscale_method': [
            ['nearest-exact', 'bilinear', 'area', 'bicubic', 'lanczos'],
            {},
          ],
        },
      },
    },
  };

  /// ComfyUI `/upload/image`: stores the multipart `image` field in the input folder.
  http.Response _uploadImage(http.Request request) {
    final boundary = RegExp('boundary=([^;]+)').firstMatch(request.headers['content-type']!)!.group(1)!;
    for (final part in _multipartParts(request.bodyBytes, boundary)) {
      final name = RegExp('filename="([^"]*)"').firstMatch(part.headers)?.group(1);
      if (RegExp('name="image"').hasMatch(part.headers) && name != null) {
        comfyInputs[name] = part.body;
        return _json({'name': name, 'subfolder': '', 'type': 'input'});
      }
    }

    return _json({'error': 'No image uploaded'}, 400);
  }

  static List<({String headers, Uint8List body})> _multipartParts(Uint8List body, String boundary) {
    final delimiter = latin1.encode('--$boundary');
    final parts = <({String headers, Uint8List body})>[];
    var start = _indexOf(body, delimiter, 0);
    while (start >= 0) {
      final contentStart = start + delimiter.length + 2;
      final next = _indexOf(body, delimiter, contentStart);
      if (next < 0) {
        break;
      }

      final part = body.sublist(contentStart, next - 2);
      final headerEnd = _indexOf(part, latin1.encode('\r\n\r\n'), 0);
      if (headerEnd >= 0) {
        parts.add((headers: latin1.decode(part.sublist(0, headerEnd)), body: part.sublist(headerEnd + 4)));
      }

      start = next;
    }

    return parts;
  }

  static int _indexOf(List<int> haystack, List<int> needle, int from) {
    outer:
    for (var index = from; index <= haystack.length - needle.length; index++) {
      for (var offset = 0; offset < needle.length; offset++) {
        if (haystack[index + offset] != needle[offset]) {
          continue outer;
        }
      }

      return index;
    }

    return -1;
  }

  // --- Rendering -----------------------------------------------------------------------------------

  Future<void> _simulate(_Task task) async {
    const steps = 6;
    for (var step = 1; step <= steps; step++) {
      if (task.interrupted || task.status == 'interrupted') {
        return;
      }

      await Future<void>.delayed(generationTime ~/ steps);
      task.progress = step / steps;
    }
  }

  Uint8List _preview(_Task task) {
    final image = img.Image(width: 32, height: 32);
    final shade = (task.progress * 255).round().clamp(0, 255);
    img.fill(image, color: img.ColorRgb8(shade, shade, 255 - shade));
    return img.encodePng(image);
  }

  Uint8List _renderWebUiImage(Map<String, Object?> request) {
    final initImages = request['init_images'] as List<Object?>?;
    final source = initImages == null || initImages.isEmpty ? null : base64.decode(initImages.first! as String);
    final denoise = (request['denoising_strength'] as num?)?.toDouble() ?? 0.75;
    final prompt = request['prompt'] as String? ?? '';
    final negative = request['negative_prompt'] as String? ?? '';
    final seed = (request['seed'] as num?)?.toInt() ?? -1;
    final width = (request['width'] as num?)?.toInt() ?? 512;
    final height = (request['height'] as num?)?.toInt() ?? 512;
    final overrides = request['override_settings'] as Map<String, Object?>?;
    final model = overrides?['sd_model_checkpoint'] as String? ?? checkpoints.first;
    final parameters = StringBuffer(prompt);
    if (negative.isNotEmpty) {
      parameters.write('\nNegative prompt: $negative');
    }

    parameters.write(
      '\nSteps: ${request['steps']}, Sampler: ${request['sampler_name'] ?? 'Euler a'}, '
      'Schedule type: ${request['scheduler'] ?? 'Automatic'}, CFG scale: ${request['cfg_scale']}, '
      'Seed: ${seed < 0 ? Random(prompt.hashCode).nextInt(1 << 31) : seed}, Size: ${width}x$height, '
      'Model: $model, Clip skip: ${overrides?['CLIP_stop_at_last_layers'] ?? 1}',
    );
    if (source != null) {
      parameters.write(', Denoising strength: $denoise');
    }

    return _render(prompt, {'parameters': parameters.toString()}, width, height, source: source, denoise: denoise);
  }

  Uint8List _renderComfyImage(Map<String, Object?> graph) {
    var text = '';
    var width = 512;
    var height = 512;
    Uint8List? source;
    var denoise = 1.0;
    var padding = (x: 0, y: 0);
    for (final node in graph.values.cast<Map<String, Object?>>()) {
      final inputs = node['inputs']! as Map<String, Object?>;
      switch (node['class_type']) {
        case 'CLIPTextEncode' when text.isEmpty:
          text = inputs['text'] as String? ?? '';
        case 'EmptyLatentImage' || 'ImageScale' || 'LatentUpscale':
          width = (inputs['width']! as num).toInt();
          height = (inputs['height']! as num).toInt();
        case 'ImagePadForOutpaint':
          padding = (
            x: (inputs['left']! as num).toInt() + (inputs['right']! as num).toInt(),
            y: (inputs['top']! as num).toInt() + (inputs['bottom']! as num).toInt(),
          );
        case 'LoadImage':
          source = comfyInputs[inputs['image']];
        case 'KSampler':
          denoise = (inputs['denoise'] as num?)?.toDouble() ?? 1.0;
      }
    }

    return _render(
      text,
      {'prompt': jsonEncode(graph)},
      width + padding.x,
      height + padding.y,
      source: source,
      denoise: denoise,
    );
  }

  /// A stylised landscape derived from the prompt (sky gradient, sun and layered hills), so different
  /// cells produce visibly different images. For img2img the [source] image shows through, more so
  /// the lower [denoise] is.
  Uint8List _render(
    String prompt,
    Map<String, String> textData,
    int width,
    int height, {
    Uint8List? source,
    double denoise = 1,
  }) {
    final aspect = width / height;
    final outWidth = max(aspect >= 1 ? imageSize : (imageSize * aspect).round(), 8);
    final outHeight = max(aspect >= 1 ? (imageSize / aspect).round() : imageSize, 8);
    final random = Random(prompt.hashCode ^ DateTime.now().microsecondsSinceEpoch);
    final hue = (prompt.hashCode % 360 + random.nextDouble() * 50) % 360;
    final sunX = 0.2 + random.nextDouble() * 0.6;
    final sunY = 0.18 + random.nextDouble() * 0.25;
    final layers = [
      for (var layer = 0; layer < 3; layer++)
        (
          base: 0.52 + layer * 0.14 + random.nextDouble() * 0.05,
          amplitude: 0.05 + random.nextDouble() * 0.06,
          frequency: 2 + random.nextDouble() * 4 + layer * 2,
          phase: random.nextDouble() * pi * 2,
        ),
    ];
    final image = img.Image(width: outWidth, height: outHeight);
    for (final pixel in image) {
      final u = pixel.x / outWidth;
      final v = pixel.y / outHeight;
      var rgb = _hsvToRgb((hue + v * 40) % 360, 0.35 + v * 0.3, 0.98 - v * 0.25);
      final dx = (u - sunX) * aspect;
      final dy = v - sunY;
      final distance = sqrt(dx * dx + dy * dy);
      if (distance < 0.08) {
        rgb = _hsvToRgb((hue + 30) % 360, 0.25, 1.0);
      } else if (distance < 0.25) {
        final glow = 1 - (distance - 0.08) / 0.17;
        final sun = _hsvToRgb((hue + 30) % 360, 0.3, 1.0);
        rgb = (_mix(rgb.$1, sun.$1, glow * 0.5), _mix(rgb.$2, sun.$2, glow * 0.5), _mix(rgb.$3, sun.$3, glow * 0.5));
      }

      for (var index = 0; index < layers.length; index++) {
        final layer = layers[index];
        final ridge = layer.base + layer.amplitude * sin(u * layer.frequency + layer.phase);
        if (v > ridge) {
          rgb = _hsvToRgb((hue + 180 + index * 12) % 360, 0.45 + index * 0.1, 0.62 - index * 0.17 - (v - ridge) * 0.3);
        }
      }

      pixel
        ..r = rgb.$1
        ..g = rgb.$2
        ..b = rgb.$3;
    }

    final decoded = source == null ? null : img.decodeImage(source);
    if (decoded != null) {
      final fitted = img.copyResize(decoded, width: outWidth, height: outHeight);
      final keep = (1 - denoise).clamp(0.0, 1.0) * 0.85 + 0.1;
      for (final pixel in image) {
        final original = fitted.getPixel(pixel.x, pixel.y);
        pixel
          ..r = _mix(pixel.r.toInt(), original.r.toInt(), keep)
          ..g = _mix(pixel.g.toInt(), original.g.toInt(), keep)
          ..b = _mix(pixel.b.toInt(), original.b.toInt(), keep);
      }
    }

    image.textData = textData;
    return img.encodePng(image);
  }

  static int _mix(int from, int to, double amount) => (from + (to - from) * amount).round().clamp(0, 255);

  static (int, int, int) _hsvToRgb(double hue, double saturation, double brightness) {
    final value = brightness.clamp(0.0, 1.0);
    final c = value * saturation;
    final x = c * (1 - ((hue / 60) % 2 - 1).abs());
    final m = value - c;
    final (r, g, b) = switch (hue) {
      < 60 => (c, x, 0.0),
      < 120 => (x, c, 0.0),
      < 180 => (0.0, c, x),
      < 240 => (0.0, x, c),
      < 300 => (x, 0.0, c),
      _ => (c, 0.0, x),
    };
    return (((r + m) * 255).round(), ((g + m) * 255).round(), ((b + m) * 255).round());
  }

  static String _title(String value) => value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  static http.Response _json(Object? body, [int statusCode = 200]) =>
      http.Response(jsonEncode(body), statusCode, headers: {'content-type': 'application/json'});
}

class _Task {
  _Task(this.id, this.request);

  final String id;
  final Map<String, Object?> request;
  String? taskId;
  String status = 'pending';
  double progress = 0;
  bool interrupted = false;
  Uint8List? image;
}
