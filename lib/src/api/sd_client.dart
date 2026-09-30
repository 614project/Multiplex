import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/cancellation.dart';
import '../core/ids.dart';
import '../core/json_read.dart';
import '../core/url_tools.dart';
import '../models/api_platform.dart';
import 'comfy_workflow.dart';
import 'sd_models.dart';

/// A non-success HTTP status returned by the server.
class HttpStatusException implements Exception {
  HttpStatusException(this.statusCode, this.path, {this.reason, this.detail});

  final int statusCode;
  final String path;
  final String? reason;
  final String? detail;

  @override
  String toString() {
    final reasonText = reason == null || reason!.isEmpty ? '' : ' $reason';
    final detailText = detail == null || detail!.isEmpty ? '' : ': $detail';
    return 'HTTP $statusCode$reasonText from $path$detailText';
  }
}

/// A server reply that the app could not use.
class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Result of a quick reachability check.
class ServerCheckResult {
  const ServerCheckResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}

/// HTTP client for Stable Diffusion WebUI (A1111/Forge), its Agent Scheduler extension and ComfyUI.
class SdClient {
  SdClient({http.Client? httpClient, this.comfyPollInterval = const Duration(seconds: 1)})
    : _http = httpClient ?? http.Client();

  static const agentSchedulerSupportCacheLifetime = Duration(minutes: 5);

  final http.Client _http;
  final Duration comfyPollInterval;
  final Map<String, ({bool? supported, DateTime checkedAt})> _agentSchedulerSupport = {};

  void close() => _http.close();

  // ---------------------------------------------------------------------------------------------
  // WebUI
  // ---------------------------------------------------------------------------------------------

  /// Runs txt2img, or img2img when the request has a source image.
  Future<GenerationResponse> generate(String baseUrl, GenerationRequest request, CancellationToken token) async {
    final json = await _sendJson('POST', baseUrl, request.webUiPath, token, body: request.toJson());
    return GenerationResponse.fromJson(json);
  }

  Future<ProgressResponse> getProgress(String baseUrl, CancellationToken token, {bool skipCurrentImage = true}) async {
    final json = await _sendJson('GET', baseUrl, '/sdapi/v1/progress?skip_current_image=$skipCurrentImage', token);
    return ProgressResponse.fromJson(json);
  }

  Future<InternalProgressResponse> getInternalProgress(
    String baseUrl,
    InternalProgressRequest request,
    CancellationToken token,
  ) async {
    final json = await _sendJson('POST', baseUrl, '/internal/progress', token, body: request.toJson());
    return InternalProgressResponse.fromJson(json);
  }

  Future<void> interrupt(String baseUrl, CancellationToken token) async {
    final response = await _send('POST', baseUrl, '/sdapi/v1/interrupt', token);
    _ensureSuccess(response, '/sdapi/v1/interrupt');
  }

  Future<List<String>> getSamplerNames(String baseUrl, CancellationToken token) =>
      _getNamedOptions(baseUrl, '/sdapi/v1/samplers', token);

  Future<List<String>> getSchedulerNames(String baseUrl, CancellationToken token) =>
      _getNamedOptions(baseUrl, '/sdapi/v1/schedulers', token, preferLabel: true);

  Future<List<String>> getCheckpointNames(String baseUrl, CancellationToken token) =>
      _getNamedOptions(baseUrl, '/sdapi/v1/sd-models', token);

  Future<List<String>> getLoraNames(String baseUrl, CancellationToken token) =>
      _getNamedOptions(baseUrl, '/sdapi/v1/loras', token);

  Future<List<String>> getUpscalerNames(String baseUrl, CancellationToken token) async {
    final upscalers = await _getNamedOptions(baseUrl, '/sdapi/v1/upscalers', token, preferName: true);
    List<String> latentModes;
    try {
      latentModes = await _getNamedOptions(baseUrl, '/sdapi/v1/latent-upscale-modes', token, preferName: true);
    } on HttpStatusException {
      latentModes = const [];
    }

    final seen = <String>{};
    return [
      for (final name in [...latentModes, ...upscalers])
        if (seen.add(name.toLowerCase())) name,
    ];
  }

  /// Checks that the server answers the API the project is configured for.
  Future<ServerCheckResult> checkServer(String baseUrl, ApiPlatform platform, CancellationToken token) async {
    try {
      if (platform.isComfyUi) {
        final stats = JsonRead.map(await _sendJson('GET', baseUrl, '/system_stats', token));
        final system = JsonRead.map(stats?['system']);
        final version = system?['comfyui_version'];
        final devices = JsonRead.list(stats?['devices']) ?? const [];
        final device = devices.isEmpty ? null : JsonRead.map(devices.first)?['name'];
        return ServerCheckResult(
          ok: true,
          message: ['ComfyUI${version is String ? ' $version' : ''}', if (device is String) device].join(' · '),
        );
      }

      final options = JsonRead.map(await _sendJson('GET', baseUrl, '/sdapi/v1/options', token));
      final model = options?['sd_model_checkpoint'];
      return ServerCheckResult(
        ok: true,
        message: model is String && model.isNotEmpty ? 'WebUI · $model' : 'WebUI API is reachable',
      );
    } on OperationCanceledException {
      rethrow;
    } on HttpStatusException catch (error) {
      final hint = error.statusCode == 404 && platform.isWebUi
          ? ' Launch WebUI with --api (and --listen for other devices).'
          : '';
      return ServerCheckResult(ok: false, message: '$error.$hint');
    } catch (error) {
      return ServerCheckResult(ok: false, message: describeError(error));
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Agent Scheduler
  // ---------------------------------------------------------------------------------------------

  /// Whether `/openapi.json` advertises the Agent Scheduler routes, or null when it cannot be told.
  Future<bool?> trySupportsAgentScheduler(String baseUrl, CancellationToken token) async {
    final cached = _agentSchedulerSupport[baseUrl];
    // Results expire so that enabling the extension (or recovering from a network error) is picked up.
    if (cached != null && DateTime.now().difference(cached.checkedAt) < agentSchedulerSupportCacheLifetime) {
      return cached.supported;
    }

    bool? result;
    try {
      final response = await _send('GET', baseUrl, '/openapi.json', token);
      if (_isSuccess(response.statusCode)) {
        final paths = JsonRead.map(JsonRead.map(_decodeJson(response))?['paths']);
        if (paths != null) {
          result =
              paths.containsKey('/agent-scheduler/v1/queue/txt2img') &&
              paths.containsKey('/agent-scheduler/v1/results/{id}');
        }
      }
    } on OperationCanceledException {
      rethrow;
    } catch (_) {
      result = null;
    }

    _agentSchedulerSupport[baseUrl] = (supported: result, checkedAt: DateTime.now());
    return result;
  }

  Future<String> queueAgentScheduler(String baseUrl, GenerationRequest request, CancellationToken token) async {
    final json = JsonRead.map(
      await _sendJson('POST', baseUrl, request.agentSchedulerQueuePath, token, body: request.toJson()),
    );
    final taskId = json?['task_id'];
    return taskId is String ? taskId : '';
  }

  /// Returns the first result image of a finished task, or null while it is not available yet.
  Future<String?> tryGetAgentSchedulerResultImage(String baseUrl, String taskId, CancellationToken token) async {
    final path = '/agent-scheduler/v1/results/${Uri.encodeComponent(taskId)}';
    final response = await _send('GET', baseUrl, path, token);
    if (response.statusCode == 404 || response.statusCode == 409) {
      return null;
    }

    _ensureSuccess(response, path);
    final data = JsonRead.list(JsonRead.map(_decodeJson(response))?['data']) ?? const [];
    for (final item in data) {
      final image = JsonRead.map(item)?['image'];
      if (image is String && image.trim().isNotEmpty) {
        return image;
      }
    }

    return null;
  }

  /// Removes a task this app queued in Agent Scheduler. Finished tasks are left alone so their results
  /// stay in the extension's history; a pending task is deleted and a running task is interrupted.
  Future<void> cancelAgentSchedulerTask(String baseUrl, String taskId, CancellationToken token) async {
    if (taskId.trim().isEmpty) {
      return;
    }

    final escaped = Uri.encodeComponent(taskId);
    final status = await _send('GET', baseUrl, '/agent-scheduler/v1/task/$escaped', token);
    if (status.statusCode == 404) {
      return;
    }

    if (_isSuccess(status.statusCode)) {
      final state = readAgentSchedulerTaskStatus(_tryDecodeJson(status));
      if (state != null && state.isNotEmpty && !_isAgentSchedulerTaskActive(state)) {
        return;
      }
    }

    final deletePath = '/agent-scheduler/v1/task/$escaped/delete';
    final delete = await _send('POST', baseUrl, deletePath, token);
    if (delete.statusCode != 404 && delete.statusCode != 405) {
      _ensureSuccess(delete, deletePath);
      return;
    }

    // Older Agent Scheduler builds only expose the legacy delete route.
    final legacyPath = '/agent-scheduler/v1/delete/$escaped';
    final legacy = await _send('POST', baseUrl, legacyPath, token);
    _ensureSuccess(legacy, legacyPath);
  }

  static String? readAgentSchedulerTaskStatus(Object? root) {
    final map = JsonRead.map(root);
    if (map == null) {
      return null;
    }

    final task = JsonRead.map(map['data']) ?? map;
    final status = task['status'];
    return status is String && status.trim().isNotEmpty ? status.trim() : null;
  }

  static bool _isAgentSchedulerTaskActive(String status) {
    final lower = status.toLowerCase();
    return lower == 'pending' || lower == 'running';
  }

  // ---------------------------------------------------------------------------------------------
  // ComfyUI
  // ---------------------------------------------------------------------------------------------

  Future<ComfyObjectInfoMetadata> getComfyMetadata(String baseUrl, CancellationToken token) async {
    final json = await _sendJson('GET', baseUrl, '/object_info', token);
    return parseObjectInfo(json);
  }

  Future<ComfyObjectInfoMetadata?> tryGetComfyMetadata(String baseUrl, CancellationToken token) async {
    try {
      return await getComfyMetadata(baseUrl, token);
    } on OperationCanceledException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  static ComfyObjectInfoMetadata parseObjectInfo(Object? json) {
    final root = JsonRead.map(json) ?? const <String, Object?>{};
    final loaderTypes = <String>[
      for (final type in ComfyLoraLoaderTypes.all)
        if (_comboValues(root, type, 'lora_name').isNotEmpty) type,
    ];
    final loraNames = <String>[];
    for (final type in ComfyLoraLoaderTypes.all) {
      for (final name in _comboValues(root, type, 'lora_name')) {
        if (!loraNames.any((existing) => existing.toLowerCase() == name.toLowerCase())) {
          loraNames.add(name);
        }
      }
    }

    return ComfyObjectInfoMetadata(
      checkpointNames: _comboValues(root, 'CheckpointLoaderSimple', 'ckpt_name'),
      samplerNames: _comboValues(root, 'KSampler', 'sampler_name'),
      schedulerNames: _comboValues(root, 'KSampler', 'scheduler'),
      latentUpscaleMethods: _comboValues(root, 'LatentUpscaleBy', 'upscale_method'),
      loraNames: loraNames,
      availableLoraLoaderTypes: loaderTypes.isEmpty ? const [ComfyLoraLoaderTypes.loraLoader] : loaderTypes,
      supportsClipSetLastLayer: root.containsKey('CLIPSetLastLayer'),
      imageScaleMethods: _comboValues(root, 'ImageScale', 'upscale_method'),
    );
  }

  /// Uploads an img2img source image into ComfyUI's input folder (replacing a file of the same
  /// name) and returns the name a `LoadImage` node refers to.
  Future<String> uploadComfyImage(String baseUrl, Uint8List bytes, String fileName, CancellationToken token) async {
    final response = await _sendMultipart(
      baseUrl,
      '/upload/image',
      token,
      fields: {'type': 'input', 'overwrite': 'true'},
      file: (field: 'image', fileName: fileName, bytes: bytes),
    );
    _ensureSuccess(response, '/upload/image');
    final json = JsonRead.map(_decodeJson(response));
    final name = _nonEmpty(json?['name']);
    if (name == null) {
      throw const ApiException('ComfyUI did not return a file name for the uploaded source image.');
    }

    final subfolder = _nonEmpty(json?['subfolder']);
    return subfolder == null ? name : '$subfolder/$name';
  }

  /// Queues the built-in workflow. img2img requests need the [sourceImageName] returned by
  /// [uploadComfyImage].
  Future<String> queueComfy(
    String baseUrl,
    GenerationRequest request,
    ComfyObjectInfoMetadata? metadata,
    CancellationToken token, {
    required String clientId,
    String? sourceImageName,
  }) async {
    metadata ??= await getComfyMetadata(baseUrl, token);
    final checkpoint = _resolveComfyCheckpoint(request, metadata.checkpointNames);
    final prompt = ComfyWorkflow.buildPrompt(
      request,
      sourceImageName: sourceImageName,
      imageScaleMethod: ComfyWorkflow.resolveImageScaleMethod(metadata.imageScaleMethods),
      checkpoint: checkpoint,
      latentUpscaleMethod: ComfyWorkflow.resolveLatentUpscaleMethod(
        request.hiresUpscaler,
        metadata.latentUpscaleMethods,
      ),
      loraLoaderType: ComfyWorkflow.resolveLoraLoaderType(
        request.comfyLoraLoaderType,
        metadata.availableLoraLoaderTypes,
      ),
      supportsClipSetLastLayer: metadata.supportsClipSetLastLayer,
    );

    final promptId = _newPromptId();
    final response = await _send(
      'POST',
      baseUrl,
      '/prompt',
      token,
      body: {'client_id': clientId, 'prompt_id': promptId, 'prompt': prompt},
    );

    final document = _tryDecodeJson(response);
    // ComfyUI answers an invalid workflow with HTTP 400 and a JSON body that explains which node failed.
    final rejection = document == null ? null : buildComfyPromptErrorMessage(document);
    if (rejection != null && rejection.isNotEmpty) {
      throw ApiException('ComfyUI rejected the workflow: $rejection');
    }

    _ensureSuccess(response, '/prompt');
    if (document == null) {
      throw const ApiException('ComfyUI returned an unreadable response for /prompt.');
    }

    final responsePromptId = JsonRead.map(document)?['prompt_id'];
    return responsePromptId is String && responsePromptId.trim().isNotEmpty ? responsePromptId : promptId;
  }

  /// Polls `/history/{id}` until the prompt produced an image and returns its bytes.
  Future<Uint8List> waitForComfyImage(String baseUrl, String promptId, CancellationToken token) async {
    while (true) {
      token.throwIfCancelled();
      final historyPath = '/history/${Uri.encodeComponent(promptId)}';
      final response = await _send('GET', baseUrl, historyPath, token);
      _ensureSuccess(response, historyPath);
      final history = JsonRead.map(_decodeJson(response));
      if (history != null) {
        final record = JsonRead.map(history[promptId]) ?? (history.containsKey('outputs') ? history : null);
        if (record != null) {
          final error = tryGetComfyPromptError(record);
          if (error != null) {
            throw ApiException(error);
          }

          final image = _tryGetComfyImageReference(record);
          if (image != null) {
            final query = [
              'filename=${Uri.encodeQueryComponent(image.fileName)}',
              'type=${Uri.encodeQueryComponent(image.type)}',
              if (image.subfolder.isNotEmpty) 'subfolder=${Uri.encodeQueryComponent(image.subfolder)}',
            ].join('&');
            final imageResponse = await _send('GET', baseUrl, '/view?$query', token);
            _ensureSuccess(imageResponse, '/view');
            return imageResponse.bodyBytes;
          }

          if (isComfyHistoryRecordFinished(record)) {
            throw const ApiException('ComfyUI finished the prompt without producing an image.');
          }
        }
      }

      await token.delay(comfyPollInterval);
    }
  }

  /// Stops work this app queued in ComfyUI: pending prompts are removed from the queue and the running
  /// prompt is interrupted only when it is one of ours, so other clients' prompts are left untouched.
  Future<void> cancelComfyPrompts(String baseUrl, List<String> promptIds, CancellationToken token) async {
    final ids = <String>[];
    for (final id in promptIds) {
      if (id.trim().isNotEmpty && !ids.contains(id)) {
        ids.add(id);
      }
    }

    if (ids.isEmpty) {
      return;
    }

    final delete = await _send('POST', baseUrl, '/queue', token, body: {'delete': ids});
    _ensureSuccess(delete, '/queue');

    final queue = await _send('GET', baseUrl, '/queue', token);
    _ensureSuccess(queue, '/queue');
    final runningPromptId = findRunningComfyPromptId(_decodeJson(queue), ids);
    if (runningPromptId == null) {
      return;
    }

    final interrupt = await _send('POST', baseUrl, '/interrupt', token, body: {'prompt_id': runningPromptId});
    _ensureSuccess(interrupt, '/interrupt');
  }

  static String? findRunningComfyPromptId(Object? queueRoot, List<String> promptIds) {
    final running = JsonRead.list(JsonRead.map(queueRoot)?['queue_running']);
    if (running == null) {
      return null;
    }

    for (final item in running) {
      // Queue items are [number, prompt_id, prompt, extra_data, outputs_to_execute].
      if (item is List && item.length >= 2 && item[1] is String && promptIds.contains(item[1])) {
        return item[1] as String;
      }
    }

    return null;
  }

  static String? buildComfyPromptErrorMessage(Object? root) {
    final map = JsonRead.map(root);
    if (map == null) {
      return null;
    }

    final messages = <String>[];
    final error = map['error'];
    if (error is String) {
      _addIfPresent(messages, error);
    } else if (JsonRead.map(error) case final errorMap?) {
      _addIfPresent(messages, _combine(_nonEmpty(errorMap['message']), _nonEmpty(errorMap['details'])));
    }

    final nodeErrors = JsonRead.map(map['node_errors']);
    if (nodeErrors != null) {
      for (final entry in nodeErrors.entries) {
        final node = JsonRead.map(entry.value);
        final classType = node == null ? null : _nonEmpty(node['class_type']);
        final label = classType == null ? 'node ${entry.key}' : '$classType (node ${entry.key})';
        final nodeMessages = <String>[];
        for (final item in JsonRead.list(node?['errors']) ?? const []) {
          final itemMap = JsonRead.map(item);
          if (itemMap != null) {
            _addIfPresent(nodeMessages, _combine(_nonEmpty(itemMap['message']), _nonEmpty(itemMap['details'])));
          }
        }

        if (nodeMessages.isEmpty) {
          nodeMessages.add('invalid input');
        }

        messages.addAll(nodeMessages.map((message) => '$label: $message'));
      }
    }

    final distinct = <String>[];
    for (final message in messages) {
      if (!distinct.contains(message)) {
        distinct.add(message);
      }
    }

    return distinct.isEmpty ? null : distinct.take(5).join('; ');
  }

  static String? tryGetComfyPromptError(Map<String, Object?> historyRecord) {
    final status = JsonRead.map(historyRecord['status']);
    final statusText = status?['status_str'];
    if (status == null || statusText is! String || statusText.toLowerCase() != 'error') {
      return null;
    }

    for (final message in JsonRead.list(status['messages']) ?? const []) {
      // Status messages are ["event_name", { ...payload }].
      if (message is! List || message.length < 2 || message[0] is! String) {
        continue;
      }

      final payload = JsonRead.map(message[1]);
      if (payload == null) {
        continue;
      }

      if (message[0] == 'execution_interrupted') {
        return 'ComfyUI interrupted the prompt.';
      }

      if (message[0] == 'execution_error') {
        final exceptionMessage = _nonEmpty(payload['exception_message']);
        final nodeType = _nonEmpty(payload['node_type']);
        if (exceptionMessage != null) {
          return nodeType == null ? exceptionMessage : '$nodeType: $exceptionMessage';
        }
      }
    }

    return _nonEmpty(historyRecord['exception_message']) ?? 'ComfyUI reported an execution error.';
  }

  static bool isComfyHistoryRecordFinished(Map<String, Object?> historyRecord) {
    final status = JsonRead.map(historyRecord['status']);
    if (status == null) {
      // Builds without a status block only write a history entry once the prompt has finished.
      return true;
    }

    if (status['completed'] == true) {
      return true;
    }

    final statusText = status['status_str'];
    return statusText is String && statusText.toLowerCase() == 'success';
  }

  static List<String> extractComfyComboValues(Object? inputValue) {
    final declared = _tryReadDeclaredComboOptions(inputValue);
    if (declared != null) {
      return declared;
    }

    var best = <String>[];
    void collect(Object? element) {
      if (element is List) {
        // ["TYPE_NAME", { ...config }] is a type descriptor, not a list of options.
        if (!_isTypeDescriptor(element)) {
          final direct = _distinctStrings(element);
          if (direct.length > best.length) {
            best = direct;
          }
        }

        for (final item in element) {
          collect(item);
        }
      } else if (element is Map) {
        for (final value in element.values) {
          collect(value);
        }
      }
    }

    collect(inputValue);
    return best;
  }

  // ComfyUI describes combo inputs in two shapes:
  //   legacy: [["a", "b"], { ...config }]
  //   V3:     ["COMBO", { "options": ["a", "b"], ...config }]
  static List<String>? _tryReadDeclaredComboOptions(Object? inputValue) {
    if (inputValue is! List || inputValue.isEmpty) {
      return null;
    }

    final first = inputValue.first;
    if (first is List) {
      return _distinctStrings(first);
    }

    if (first is String && inputValue.length > 1 && inputValue[1] is Map) {
      final options = (inputValue[1] as Map)['options'];
      if (options is List) {
        return _distinctStrings(options);
      }
    }

    return null;
  }

  static bool _isTypeDescriptor(List<Object?> array) =>
      array.length >= 2 && array.first is String && array.skip(1).any((item) => item is Map);

  static List<String> _distinctStrings(List<Object?> array) {
    final seen = <String>{};
    return [
      for (final value in array)
        if (value is String && value.trim().isNotEmpty && seen.add(value.toLowerCase())) value,
    ];
  }

  static List<String> _comboValues(Map<String, Object?> root, String nodeClass, String inputName) {
    final input = JsonRead.map(JsonRead.map(root[nodeClass])?['input']);
    if (input == null) {
      return const [];
    }

    for (final section in const ['required', 'optional']) {
      final sectionMap = JsonRead.map(input[section]);
      if (sectionMap == null || !sectionMap.containsKey(inputName)) {
        continue;
      }

      final values = extractComfyComboValues(sectionMap[inputName]);
      if (values.isNotEmpty) {
        return values;
      }
    }

    return const [];
  }

  static String _resolveComfyCheckpoint(GenerationRequest request, List<String> checkpoints) {
    final configured = request.sdModelCheckpoint;
    if (configured != null && configured.trim().isNotEmpty) {
      return configured;
    }

    final first = checkpoints.where((name) => name.trim().isNotEmpty).firstOrNull;
    if (first != null) {
      return first;
    }

    throw const ApiException(
      'ComfyUI did not report any checkpoints. Select a checkpoint or verify /object_info is available.',
    );
  }

  static ({String fileName, String subfolder, String type})? _tryGetComfyImageReference(Map<String, Object?> record) {
    final outputs = JsonRead.map(record['outputs']);
    if (outputs == null) {
      return null;
    }

    ({String fileName, String subfolder, String type})? best;
    var bestOrder = -1 << 62;
    for (final output in outputs.entries) {
      final images = JsonRead.list(JsonRead.map(output.value)?['images']);
      if (images == null) {
        continue;
      }

      ({String fileName, String subfolder, String type})? candidate;
      for (final image in images) {
        final imageMap = JsonRead.map(image);
        final fileName = imageMap?['filename'];
        if (imageMap == null || fileName is! String || fileName.trim().isEmpty) {
          continue;
        }

        final subfolder = imageMap['subfolder'];
        final type = imageMap['type'];
        candidate = (
          fileName: fileName,
          subfolder: subfolder is String ? subfolder : '',
          type: type is String ? type : 'output',
        );
        break;
      }

      if (candidate == null) {
        continue;
      }

      final order = int.tryParse(output.key) ?? 0;
      if (best == null || order >= bestOrder) {
        best = candidate;
        bestOrder = order;
      }
    }

    return best;
  }

  static String _newPromptId() => newId();

  // ---------------------------------------------------------------------------------------------
  // Transport
  // ---------------------------------------------------------------------------------------------

  Future<List<String>> _getNamedOptions(
    String baseUrl,
    String path,
    CancellationToken token, {
    bool preferLabel = false,
    bool preferName = false,
  }) async {
    final json = await _sendJson('GET', baseUrl, path, token);
    if (json is! List) {
      return const [];
    }

    final keys = preferLabel
        ? const ['label', 'title', 'alias', 'name', 'filename', 'model_name']
        : preferName
        ? const ['name', 'title', 'alias', 'label', 'filename', 'model_name']
        : const ['title', 'alias', 'name', 'filename', 'model_name', 'label'];
    final values = <String>[];
    for (final item in json) {
      String? name;
      if (item is String) {
        name = item;
      } else if (JsonRead.map(item) case final map?) {
        for (final key in keys) {
          if (map[key] is String) {
            name = map[key] as String;
            break;
          }
        }
      }

      if (name != null &&
          name.trim().isNotEmpty &&
          !values.any((existing) => existing.toLowerCase() == name!.toLowerCase())) {
        values.add(name);
      }
    }

    return values;
  }

  Future<Object?> _sendJson(String method, String baseUrl, String path, CancellationToken token, {Object? body}) async {
    final response = await _send(method, baseUrl, path, token, body: body);
    _ensureSuccess(response, path);
    return _decodeJson(response);
  }

  Future<http.Response> _send(
    String method,
    String baseUrl,
    String path,
    CancellationToken token, {
    Object? body,
  }) async {
    token.throwIfCancelled();
    final endpoint = EndpointResolver.resolve(baseUrl, path);
    final request = http.AbortableRequest(
      method,
      endpoint.uri,
      abortTrigger: identical(token, CancellationToken.none) ? null : token.whenCancelled,
    );
    if (endpoint.basicAuthorization != null) {
      request.headers['Authorization'] = endpoint.basicAuthorization!;
    }

    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(body));
    }

    try {
      final streamed = await token.guard(_http.send(request));
      return await token.guard(http.Response.fromStream(streamed));
    } on http.RequestAbortedException {
      throw const OperationCanceledException();
    } on http.ClientException {
      if (token.isCancelled) {
        throw const OperationCanceledException();
      }

      rethrow;
    }
  }

  Future<http.Response> _sendMultipart(
    String baseUrl,
    String path,
    CancellationToken token, {
    required Map<String, String> fields,
    required ({String field, String fileName, Uint8List bytes}) file,
  }) async {
    token.throwIfCancelled();
    final endpoint = EndpointResolver.resolve(baseUrl, path);
    final request = http.AbortableMultipartRequest(
      'POST',
      endpoint.uri,
      abortTrigger: identical(token, CancellationToken.none) ? null : token.whenCancelled,
    );
    if (endpoint.basicAuthorization != null) {
      request.headers['Authorization'] = endpoint.basicAuthorization!;
    }

    request.fields.addAll(fields);
    request.files.add(http.MultipartFile.fromBytes(file.field, file.bytes, filename: file.fileName));

    try {
      final streamed = await token.guard(_http.send(request));
      return await token.guard(http.Response.fromStream(streamed));
    } on http.RequestAbortedException {
      throw const OperationCanceledException();
    } on http.ClientException {
      if (token.isCancelled) {
        throw const OperationCanceledException();
      }

      rethrow;
    }
  }

  static bool _isSuccess(int statusCode) => statusCode >= 200 && statusCode < 300;

  static void _ensureSuccess(http.Response response, String path) {
    if (_isSuccess(response.statusCode)) {
      return;
    }

    throw HttpStatusException(
      response.statusCode,
      path.split('?').first,
      reason: response.reasonPhrase,
      detail: _describeErrorBody(response),
    );
  }

  static String? _describeErrorBody(http.Response response) {
    final json = _tryDecodeJson(response);
    final map = JsonRead.map(json);
    final detail = map?['detail'] ?? map?['error'] ?? map?['message'];
    if (detail is String && detail.trim().isNotEmpty) {
      return _truncate(detail.trim());
    }

    if (detail != null) {
      return _truncate(jsonEncode(detail));
    }

    final text = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    return text.isEmpty || text.startsWith('<') ? null : _truncate(text);
  }

  static String _truncate(String text) => text.length > 300 ? '${text.substring(0, 300)}…' : text;

  static Object? _decodeJson(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    try {
      return jsonDecode(text);
    } on FormatException {
      throw ApiException('The server returned an unreadable response (${response.request?.url.path}).');
    }
  }

  static Object? _tryDecodeJson(http.Response response) {
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (text.trim().isEmpty) {
      return null;
    }

    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static void _addIfPresent(List<String> values, String? value) {
    if (value != null && value.trim().isNotEmpty) {
      values.add(value.trim());
    }
  }

  static String? _combine(String? message, String? details) {
    if (message == null) {
      return details;
    }

    return details == null || message == details ? message : '$message ($details)';
  }

  static String? _nonEmpty(Object? value) => value is String && value.trim().isNotEmpty ? value.trim() : null;

  /// Human readable description of a failure for messages shown to the user.
  static String describeError(Object error) {
    if (error is http.ClientException) {
      final message = error.message;
      final lower = message.toLowerCase();
      if (lower.contains('connection refused') ||
          lower.contains('failed host lookup') ||
          lower.contains('network is unreachable')) {
        return 'Could not reach the server (${error.uri ?? 'unknown address'}). Check the API base URL and that the server is running with network access enabled.';
      }

      return message;
    }

    if (error is ArgumentError) {
      return error.message.toString();
    }

    return error.toString().replaceFirst(RegExp(r'^(Exception|Bad state|SocketException): '), '');
  }
}
