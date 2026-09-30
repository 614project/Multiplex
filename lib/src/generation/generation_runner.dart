import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../api/sd_client.dart';
import '../api/sd_models.dart';
import '../core/cancellation.dart';
import '../core/ids.dart';
import '../core/image_signature.dart';
import '../core/option_lists.dart';
import '../core/prompt_composer.dart';
import '../models/img2img.dart';
import '../models/lora_selection.dart';
import '../services/file_io.dart';
import '../services/source_images.dart';
import '../state/app_messenger.dart';
import 'generation_context.dart';

/// What the runner needs from the project that owns the job.
abstract interface class GenerationHost {
  bool get stopAfterCurrentImageRequested;
  bool get forceInterruptRequested;
  bool get livePreviewEnabled;

  /// Set after a force stop or timeout on WebUI so the next job waits for the server to go idle.
  bool get waitForWebUiIdle;
  set waitForWebUiIdle(bool value);

  bool isCellAlive(String cellId);
  void setCellBusy(String cellId, bool busy);
  void setCellPreview(String cellId, Uint8List? preview, double? progress);

  /// Status line of the running job (the Generate button text of WebuiMultiflex).
  void setStatus(String text, {double? imageProgress});
  void markRequestCompleted();
  void report(String message, MessageSeverity severity);

  /// Stores an image produced for [cell]; discards it when the cell or project no longer exists.
  Future<void> saveImage(CellSnapshot cell, Uint8List bytes);
  void storeComfyMetadata(String baseUrl, ComfyObjectInfoMetadata metadata);
}

/// Runs one queued job against WebUI (standard, polling or Agent Scheduler) or ComfyUI.
///
/// This is a direct port of the WebuiMultiflex generation loops (extended with img2img), including the
/// proxy-safe recovery of dropped image responses, Agent Scheduler/ComfyUI prefetching and server-side cleanup of work that
/// was queued by a job which is force-stopped or times out.
class GenerationRunner {
  GenerationRunner(this.host, this.client, {this.pollInterval = const Duration(seconds: 1)});

  static const interruptRequestTimeout = Duration(seconds: 5);
  static const serverCleanupTimeout = Duration(seconds: 10);
  static const maximumRequestTimeout = Duration(days: 30);

  final GenerationHost host;
  final SdClient client;
  final Duration pollInterval;

  /// A ComfyUI client id shared by every prompt of this runner.
  final String comfyClientId = newId();

  // Per job: img2img source images read from disk, and their names in ComfyUI's input folder.
  final Map<String, Img2ImgSource> _sources = {};
  final Map<String, String> _comfyUploads = {};

  bool get _isStopRequested => host.stopAfterCurrentImageRequested || host.forceInterruptRequested;
  bool get _isSoftStopRequested => host.stopAfterCurrentImageRequested && !host.forceInterruptRequested;

  Future<void> run(GenerationContext context, CancellationToken token) async {
    if (context.platform.isWebUi && host.waitForWebUiIdle) {
      await _waitForWebUiToBecomeIdle(context, token);
      host.waitForWebUiIdle = false;
    }

    try {
      if (context.platform.isComfyUi) {
        await _runComfy(context, token);
      } else if (context.isAgentSchedulerMode) {
        await _runAgentScheduler(context, token);
      } else {
        await _runSequential(context, token);
      }
    } finally {
      _sources.clear();
      _comfyUploads.clear();
    }
  }

  /// Builds the request for [cell], reading its img2img source image first when the job needs one.
  Future<GenerationRequest> _prepareRequest(GenerationContext context, CellSnapshot cell) async =>
      buildRequest(context, cell, source: await _loadSource(context, cell));

  Future<Img2ImgSource?> _loadSource(GenerationContext context, CellSnapshot cell) async {
    if (!context.isImg2Img) {
      return null;
    }

    final path = context.sourceImageFor(cell);
    if (path == null) {
      throw ApiException(
        '${cell.displayName} has no source image. Choose one for the cell or in the project settings.',
      );
    }

    final cached = _sources[path];
    if (cached != null) {
      return cached;
    }

    final bytes = await FileIo.tryReadBytes(path);
    if (bytes == null) {
      throw ApiException('The source image of ${cell.displayName} was not found (${p.basename(path)}).');
    }

    final info = SourceImages.readInfo(bytes);
    if (info == null) {
      throw ApiException('The source image of ${cell.displayName} is not a PNG, JPEG, WebP or BMP image.');
    }

    return _sources[path] = Img2ImgSource(
      bytes: bytes,
      width: info.width,
      height: info.height,
      fileName: p.basename(path),
    );
  }

  /// Uploads the source image once per job and returns its name in ComfyUI's input folder.
  Future<String?> _uploadComfySource(GenerationContext context, Img2ImgSource? source, CancellationToken token) async {
    if (source == null) {
      return null;
    }

    final uploaded = _comfyUploads[source.fileName];
    if (uploaded != null) {
      return uploaded;
    }

    return _comfyUploads[source.fileName] = await client.uploadComfyImage(
      context.apiBaseUrl,
      source.bytes,
      'multiplex-${source.fileName}',
      token,
    );
  }

  CancellationSource _requestCancellation(GenerationContext context, CancellationToken token) {
    final timeout = context.timeout <= Duration.zero || context.timeout > maximumRequestTimeout
        ? maximumRequestTimeout
        : context.timeout;
    return CancellationSource(parent: token, timeout: timeout);
  }

  // -----------------------------------------------------------------------------------------------
  // WebUI: standard and polling (proxy safe)
  // -----------------------------------------------------------------------------------------------

  Future<void> _runSequential(GenerationContext context, CancellationToken token) async {
    final total = context.targets.length;
    var current = 0;
    var stoppedAfterRequestedImage = false;

    for (final cell in context.targets) {
      if (current > 0 && _isSoftStopRequested) {
        stoppedAfterRequestedImage = true;
        break;
      }

      current++;
      host.setStatus('Generating... ($current/$total)');
      if (!host.isCellAlive(cell.id)) {
        _reportRemovedCell(cell);
        continue;
      }

      host.setCellBusy(cell.id, true);
      GenerationRequest? request;
      final requestSource = _requestCancellation(context, token);
      try {
        token.throwIfCancelled();
        request = await _prepareRequest(context, cell);
        final bytes = await _generateWebUi(context, request, cell, current, total, requestSource.token);
        if (bytes == null) {
          host.report('No image data returned from generation.', MessageSeverity.warning);
          continue;
        }

        requestSource.token.throwIfCancelled();
        await host.saveImage(cell, bytes);
      } on OperationCanceledException {
        if (token.isCancelled) {
          _reportStopped(context);
          break;
        }

        _reportTimedOut(context);
        await _stopTimedOutWebUiRequest(context, request?.forceTaskId);
        break;
      } catch (error) {
        _reportFailed(context, error);
      } finally {
        requestSource.dispose();
        host.setCellBusy(cell.id, false);
        host.markRequestCompleted();
      }
    }

    if (stoppedAfterRequestedImage) {
      host.report('Stopped after the last requested image in ${context.projectName}.', MessageSeverity.info);
    }
  }

  Future<Uint8List?> _generateWebUi(
    GenerationContext context,
    GenerationRequest request,
    CellSnapshot cell,
    int current,
    int total,
    CancellationToken token,
  ) async {
    final polling = context.isPollingMode;
    if (!polling && !host.livePreviewEnabled) {
      final response = await client.generate(context.apiBaseUrl, request, token);
      return ImageSignature.tryDecodeBase64(response.firstImage);
    }

    final taskId = ensureTaskId(request);
    final expectTwoPass = request.enableHiresFix == true;
    final tracker = WebUiRecoveryTracker(minimumRecoverablePixelCount(request));
    var completed = false;
    final generation = client.generate(context.apiBaseUrl, request, token);
    final done = generation.then<void>((_) {}, onError: (Object _) {}).whenComplete(() => completed = true);

    while (!completed) {
      await Future.any([done, token.sleep(pollInterval)]);
      if (completed) {
        break;
      }

      token.throwIfCancelled();
      await _observeWebUiProgress(context, cell, taskId, current, total, token, tracker, expectTwoPass);
    }

    try {
      final response = await generation;
      return ImageSignature.tryDecodeBase64(response.firstImage);
    } catch (error) {
      // A dropped connection only counts as a proxy drop when the progress APIs answered meanwhile;
      // otherwise the server itself is unreachable and the original error is more useful.
      if (!polling ||
          error is OperationCanceledException ||
          !isRecoverableProxyError(error) ||
          (error is! HttpStatusException && !tracker.progressApiAvailable)) {
        rethrow;
      }

      final recovered = await _recoverDroppedWebUiResponse(
        context,
        cell,
        taskId,
        current,
        total,
        token,
        expectTwoPass,
        tracker,
        'Polling mode',
      );
      if (recovered != null) {
        return ImageSignature.tryDecodeBase64(recovered);
      }

      throw ApiException(_describeDroppedResponse(tracker, expectTwoPass, 'Polling mode'));
    }
  }

  Future<void> _observeWebUiProgress(
    GenerationContext context,
    CellSnapshot cell,
    String taskId,
    int current,
    int total,
    CancellationToken token,
    WebUiRecoveryTracker tracker,
    bool expectTwoPass,
  ) async {
    final snapshot = await _getWebUiProgressSnapshot(
      context.apiBaseUrl,
      taskId,
      tracker.lastInternalLivePreviewId,
      includeClassicImage: false,
      token: token,
    );
    tracker.observe(snapshot, expectTwoPass);
    if (snapshot.internalAvailable || snapshot.classicAvailable) {
      host.setStatus(
        buildWebUiProgressText(snapshot, current, total, '', expectTwoPass),
        imageProgress: snapshot.progressValue,
      );
      _publishPreview(cell, snapshot);
    }
  }

  void _publishPreview(CellSnapshot cell, WebUiProgressSnapshot snapshot) {
    if (!host.livePreviewEnabled) {
      return;
    }

    final preview = ImageSignature.tryDecodeBase64(snapshot.internal?.livePreview);
    host.setCellPreview(cell.id, preview, snapshot.progressValue);
  }

  Future<String?> _recoverDroppedWebUiResponse(
    GenerationContext context,
    CellSnapshot cell,
    String taskId,
    int current,
    int total,
    CancellationToken token,
    bool expectTwoPass,
    WebUiRecoveryTracker tracker,
    String modeLabel,
  ) async {
    DateTime? recoveryDeadline;
    while (true) {
      token.throwIfCancelled();
      final snapshot = await _getWebUiProgressSnapshot(
        context.apiBaseUrl,
        taskId,
        tracker.lastInternalLivePreviewId,
        includeClassicImage: true,
        token: token,
      );
      tracker.observe(snapshot, expectTwoPass);

      if (!snapshot.internalAvailable && !snapshot.classicAvailable) {
        return tracker.bestRecoverableImage;
      }

      final generationCompleted = snapshot.internal?.completed == true || isGenerationIdle(snapshot.classic);
      if (generationCompleted) {
        recoveryDeadline ??= DateTime.now().add(Duration(seconds: context.pollingRecoveryGraceSeconds.clamp(0, 30)));
        if (!DateTime.now().isBefore(recoveryDeadline)) {
          return tracker.bestRecoverableImage;
        }

        final remaining = (recoveryDeadline.difference(DateTime.now()).inMilliseconds / 1000).ceil();
        host.setStatus(
          remaining > 0
              ? 'Waiting for a newer final preview... ($current/$total) [${remaining}s]'
              : 'Collecting final preview... ($current/$total)',
        );
        await token.delay(const Duration(milliseconds: 500));
        continue;
      }

      recoveryDeadline = null;
      host.setStatus(
        buildWebUiProgressText(snapshot, current, total, ' (Recovering via $modeLabel)', expectTwoPass),
        imageProgress: snapshot.progressValue,
      );
      _publishPreview(cell, snapshot);
      await token.delay(pollInterval);
    }
  }

  /// A timed-out txt2img request keeps running inside WebUI. Interrupt it while it is still the active
  /// task, and make the next job wait for WebUI to go idle instead of queueing behind it.
  Future<void> _stopTimedOutWebUiRequest(GenerationContext context, String? taskId) async {
    if (!context.platform.isWebUi) {
      return;
    }

    host.waitForWebUiIdle = true;
    if (taskId == null || taskId.trim().isEmpty) {
      return;
    }

    final cleanup = CancellationSource(timeout: serverCleanupTimeout);
    try {
      final progress = await client.getInternalProgress(
        context.apiBaseUrl,
        InternalProgressRequest(taskId: taskId, livePreview: false),
        cleanup.token,
      );
      if (progress.active) {
        await client.interrupt(context.apiBaseUrl, cleanup.token);
      }
    } catch (_) {
      // Best effort: the next job waits for WebUI to become idle anyway.
    } finally {
      cleanup.dispose();
    }
  }

  Future<void> _waitForWebUiToBecomeIdle(GenerationContext context, CancellationToken token) async {
    var consecutiveIdleSamples = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      token.throwIfCancelled();
      try {
        final progress = await client.getProgress(context.apiBaseUrl, token);
        if (isGenerationIdle(progress)) {
          consecutiveIdleSamples++;
          if (consecutiveIdleSamples >= 2) {
            return;
          }
        } else {
          consecutiveIdleSamples = 0;
        }
      } on OperationCanceledException {
        rethrow;
      } catch (_) {
        return;
      }

      host.setStatus('Waiting for WebUI to become idle...');
      await token.delay(const Duration(milliseconds: 500));
    }
  }

  Future<WebUiProgressSnapshot> _getWebUiProgressSnapshot(
    String baseUrl,
    String? taskId,
    int lastInternalLivePreviewId, {
    required bool includeClassicImage,
    required CancellationToken token,
  }) async {
    InternalProgressResponse? internal;
    if (taskId != null && taskId.trim().isNotEmpty) {
      try {
        internal = await client.getInternalProgress(
          baseUrl,
          InternalProgressRequest(taskId: taskId, livePreviewId: lastInternalLivePreviewId),
          token,
        );
      } on OperationCanceledException {
        rethrow;
      } catch (_) {
        internal = null;
      }
    }

    ProgressResponse? classic;
    try {
      classic = await client.getProgress(baseUrl, token, skipCurrentImage: !includeClassicImage);
    } on OperationCanceledException {
      rethrow;
    } catch (_) {
      classic = null;
    }

    return WebUiProgressSnapshot(internal, classic);
  }

  // -----------------------------------------------------------------------------------------------
  // WebUI: Agent Scheduler
  // -----------------------------------------------------------------------------------------------

  Future<void> _runAgentScheduler(GenerationContext context, CancellationToken token) async {
    final total = context.targets.length;
    var nextIndexToQueue = 0;
    var stoppedAfterRequestedImage = false;
    _AgentQueued? prefetched;

    // Tasks queued in Agent Scheduler whose result has not been collected yet. Whatever is left here
    // when the loop ends (interrupt, timeout, failure) is removed from the Agent Scheduler queue.
    final outstandingTaskIds = <String>[];

    Future<_AgentQueued?> queueNext({required bool advanceOnFailure, required CancellationToken queueToken}) async {
      nextIndexToQueue = _skipRemovedCells(context, nextIndexToQueue);
      if (nextIndexToQueue >= total) {
        return null;
      }

      final index = nextIndexToQueue;
      if (advanceOnFailure) {
        nextIndexToQueue++;
      }

      final queued = await _queueAgentSchedulerGeneration(context, index, total, queueToken);
      if (!advanceOnFailure) {
        nextIndexToQueue++;
      }

      outstandingTaskIds.add(queued.queueTaskId);
      return queued;
    }

    try {
      while (true) {
        var currentGeneration = prefetched;
        prefetched = null;

        if (currentGeneration == null) {
          nextIndexToQueue = _skipRemovedCells(context, nextIndexToQueue);
          if (nextIndexToQueue >= total) {
            break;
          }

          if (token.isCancelled) {
            _reportStopped(context);
            break;
          }

          if (nextIndexToQueue > 0 && host.stopAfterCurrentImageRequested) {
            stoppedAfterRequestedImage = true;
            break;
          }

          final queueSource = _requestCancellation(context, token);
          try {
            currentGeneration = await queueNext(advanceOnFailure: true, queueToken: queueSource.token);
          } on OperationCanceledException {
            if (token.isCancelled) {
              _reportStopped(context);
              break;
            }

            _reportTimedOut(context);
            host.markRequestCompleted();
            break;
          } catch (error) {
            _reportFailed(context, error);
            host.markRequestCompleted();
            continue;
          } finally {
            queueSource.dispose();
          }

          if (currentGeneration == null) {
            continue;
          }
        }

        final generation = currentGeneration;
        final alive = host.isCellAlive(generation.cell.id);
        if (alive) {
          host.setCellBusy(generation.cell.id, true);
        }

        final requestSource = _requestCancellation(context, token);
        try {
          token.throwIfCancelled();

          Future<void> tryPrefetchNext() async {
            if (prefetched != null || nextIndexToQueue >= total || _isStopRequested) {
              return;
            }

            try {
              prefetched = await queueNext(advanceOnFailure: false, queueToken: requestSource.token);
            } on OperationCanceledException {
              rethrow;
            } catch (_) {
              // A failed prefetch must not cost the image that is already being generated.
              // The same cell is queued again once the current result has been collected.
            }
          }

          final image = await _waitForAgentSchedulerGeneration(
            context,
            generation,
            total,
            requestSource.token,
            nextIndexToQueue < total ? tryPrefetchNext : null,
          );
          outstandingTaskIds.remove(generation.queueTaskId);
          final bytes = ImageSignature.tryDecodeBase64(image);
          if (bytes == null) {
            host.report('No image data returned from generation.', MessageSeverity.warning);
          } else {
            requestSource.token.throwIfCancelled();
            await host.saveImage(generation.cell, bytes);
          }
        } on OperationCanceledException {
          if (token.isCancelled) {
            _reportStopped(context);
            break;
          }

          _reportTimedOut(context);
          break;
        } catch (error) {
          _reportFailed(context, error);
        } finally {
          requestSource.dispose();
          if (alive) {
            host.setCellBusy(generation.cell.id, false);
          }

          host.markRequestCompleted();
        }
      }
    } finally {
      await _cancelOutstandingAgentSchedulerTasks(context, outstandingTaskIds);
    }

    if (stoppedAfterRequestedImage) {
      host.report('Stopped after the last requested image in ${context.projectName}.', MessageSeverity.info);
    }
  }

  Future<_AgentQueued> _queueAgentSchedulerGeneration(
    GenerationContext context,
    int index,
    int total,
    CancellationToken token,
  ) async {
    final cell = context.targets[index];
    final request = await _prepareRequest(context, cell);
    host.setStatus('Queueing Agent Scheduler... (${index + 1}/$total)');
    final forcedTaskId = ensureTaskId(request);

    final supported = await client.trySupportsAgentScheduler(context.apiBaseUrl, token);
    if (supported == false) {
      throw const ApiException(
        'This WebUI instance does not advertise Agent Scheduler routes in /openapi.json. The extension may be '
        'installed on disk but is not mounted at runtime, is incompatible with the current WebUI build, or your '
        'proxy is not exposing custom /agent-scheduler/v1 routes.',
      );
    }

    String taskId;
    try {
      taskId = await client.queueAgentScheduler(context.apiBaseUrl, request, token);
    } on HttpStatusException catch (error) {
      if (error.statusCode == 404) {
        throw const ApiException(
          'Agent Scheduler API endpoint was not found. If the extension is installed, the current server or proxy '
          'is not exposing /agent-scheduler/v1 routes.',
        );
      }

      if (error.statusCode == 401 || error.statusCode == 403) {
        throw const ApiException(
          'Agent Scheduler API rejected the request. If your WebUI uses --api-auth, include credentials in the API '
          'Base URL (http://user:password@host:7860).',
        );
      }

      rethrow;
    }

    if (taskId.trim().isEmpty) {
      throw const ApiException('Agent Scheduler did not return a valid task_id.');
    }

    return _AgentQueued(cell, request, taskId, forcedTaskId, index + 1);
  }

  Future<String?> _waitForAgentSchedulerGeneration(
    GenerationContext context,
    _AgentQueued queued,
    int total,
    CancellationToken token,
    Future<void> Function()? tryPrefetchNext,
  ) async {
    final expectTwoPass = queued.request.enableHiresFix == true;
    final tracker = WebUiRecoveryTracker(minimumRecoverablePixelCount(queued.request));
    final progressTaskIds = <String>{queued.queueTaskId, queued.forcedTaskId}.where((id) => id.isNotEmpty).toList();
    DateTime? completionObservedAt;
    var prefetchTriggered = false;

    while (true) {
      token.throwIfCancelled();
      var result = await _tryGetAgentSchedulerResult(context.apiBaseUrl, queued.queueTaskId, token);
      if (result != null) {
        return result;
      }

      final snapshot = await _getBestAgentSchedulerSnapshot(
        context.apiBaseUrl,
        progressTaskIds,
        tracker.lastInternalLivePreviewId,
        includeClassicImage: completionObservedAt != null,
        token: token,
      );
      tracker.observe(snapshot, expectTwoPass);
      _updateAgentStatusText(snapshot, queued.position, total, expectTwoPass);
      _publishPreview(queued.cell, snapshot);

      if (!prefetchTriggered &&
          tryPrefetchNext != null &&
          _shouldPrefetchNextAgentGeneration(snapshot, completionObservedAt)) {
        prefetchTriggered = true;
        await tryPrefetchNext();
      }

      if (snapshot.internal?.completed == true || isGenerationIdle(snapshot.classic)) {
        completionObservedAt ??= DateTime.now();
        if (!prefetchTriggered && tryPrefetchNext != null) {
          prefetchTriggered = true;
          await tryPrefetchNext();
        }

        final grace = Duration(
          seconds: context.pollingRecoveryGraceSeconds < 1 ? 1 : context.pollingRecoveryGraceSeconds,
        );
        if (!DateTime.now().isBefore(completionObservedAt.add(grace))) {
          result = await _tryGetAgentSchedulerResult(context.apiBaseUrl, queued.queueTaskId, token);
          if (result != null) {
            return result;
          }

          if (tracker.bestRecoverableImage != null) {
            return tracker.bestRecoverableImage;
          }
        }
      } else {
        completionObservedAt = null;
      }

      await token.delay(const Duration(milliseconds: 1500));
    }
  }

  Future<String?> _tryGetAgentSchedulerResult(String baseUrl, String taskId, CancellationToken token) =>
      client.tryGetAgentSchedulerResultImage(baseUrl, taskId, token);

  Future<WebUiProgressSnapshot> _getBestAgentSchedulerSnapshot(
    String baseUrl,
    List<String> taskIds,
    int lastInternalLivePreviewId, {
    required bool includeClassicImage,
    required CancellationToken token,
  }) async {
    WebUiProgressSnapshot? fallback;
    for (final taskId in taskIds) {
      final snapshot = await _getWebUiProgressSnapshot(
        baseUrl,
        taskId,
        lastInternalLivePreviewId,
        includeClassicImage: includeClassicImage,
        token: token,
      );
      if (snapshot.internal?.isMeaningful == true) {
        return snapshot;
      }

      fallback ??= snapshot;
    }

    return fallback ??
        await _getWebUiProgressSnapshot(
          baseUrl,
          null,
          lastInternalLivePreviewId,
          includeClassicImage: includeClassicImage,
          token: token,
        );
  }

  static bool _shouldPrefetchNextAgentGeneration(WebUiProgressSnapshot snapshot, DateTime? completionObservedAt) {
    if (completionObservedAt != null) {
      return true;
    }

    final progress = snapshot.internal?.progress ?? snapshot.classic?.progress ?? 0;
    final eta = snapshot.internal?.eta ?? snapshot.classic?.etaRelative ?? double.infinity;
    if (progress >= 0.82) {
      return true;
    }

    if (eta > 0 && eta <= 2.5) {
      return true;
    }

    return snapshot.internal?.completed == true;
  }

  void _updateAgentStatusText(WebUiProgressSnapshot snapshot, int current, int total, bool expectTwoPass) {
    final internal = snapshot.internal;
    if (internal != null && internal.queued && !internal.active && !internal.completed) {
      host.setStatus('Queued in Agent Scheduler... ($current/$total)');
      return;
    }

    if (internal?.completed == true) {
      host.setStatus('Collecting Agent Scheduler result... ($current/$total)', imageProgress: 1);
      return;
    }

    if (snapshot.internalAvailable || snapshot.classicAvailable) {
      host.setStatus(
        buildWebUiProgressText(snapshot, current, total, ' (Agent)', expectTwoPass),
        imageProgress: snapshot.progressValue,
      );
      return;
    }

    host.setStatus('Waiting for Agent Scheduler... ($current/$total)');
  }

  Future<void> _cancelOutstandingAgentSchedulerTasks(GenerationContext context, List<String> taskIds) async {
    if (taskIds.isEmpty) {
      return;
    }

    final cleanup = CancellationSource(timeout: serverCleanupTimeout);
    try {
      for (final taskId in [...taskIds]) {
        try {
          await client.cancelAgentSchedulerTask(context.apiBaseUrl, taskId, cleanup.token);
        } catch (_) {
          // Best effort cleanup.
        }
      }
    } finally {
      cleanup.dispose();
    }
  }

  // -----------------------------------------------------------------------------------------------
  // ComfyUI
  // -----------------------------------------------------------------------------------------------

  Future<void> _runComfy(GenerationContext context, CancellationToken token) async {
    final total = context.targets.length;
    var nextIndexToQueue = 0;
    var stoppedAfterRequestedImage = false;
    ComfyObjectInfoMetadata? metadata;
    _ComfyQueued? prefetched;

    // Prompts that are queued in ComfyUI but whose image has not been collected yet. Whatever is left
    // here when the loop ends (interrupt, timeout, failure) is removed from the ComfyUI queue.
    final outstandingPromptIds = <String>[];

    Future<_ComfyQueued?> queueNext({required bool advanceOnFailure, required CancellationToken queueToken}) async {
      nextIndexToQueue = _skipRemovedCells(context, nextIndexToQueue);
      if (nextIndexToQueue >= total) {
        return null;
      }

      final index = nextIndexToQueue;
      if (advanceOnFailure) {
        nextIndexToQueue++;
      }

      if (metadata == null) {
        // /object_info can be several megabytes, so it is fetched once per job instead of once per image.
        final loaded = await client.getComfyMetadata(context.apiBaseUrl, queueToken);
        host.storeComfyMetadata(context.apiBaseUrl, loaded);
        metadata = loaded;
      }

      final cell = context.targets[index];
      host.setStatus('Queueing ComfyUI... (${index + 1}/$total)');
      final request = await _prepareRequest(context, cell);
      final promptId = await client.queueComfy(
        context.apiBaseUrl,
        request,
        metadata,
        queueToken,
        clientId: comfyClientId,
        sourceImageName: await _uploadComfySource(context, request.source, queueToken),
      );
      if (!advanceOnFailure) {
        nextIndexToQueue++;
      }

      outstandingPromptIds.add(promptId);
      return _ComfyQueued(cell, promptId, index + 1);
    }

    try {
      while (true) {
        var currentGeneration = prefetched;
        prefetched = null;

        if (currentGeneration == null) {
          nextIndexToQueue = _skipRemovedCells(context, nextIndexToQueue);
          if (nextIndexToQueue >= total) {
            break;
          }

          if (token.isCancelled) {
            _reportStopped(context);
            break;
          }

          if (nextIndexToQueue > 0 && host.stopAfterCurrentImageRequested) {
            stoppedAfterRequestedImage = true;
            break;
          }

          final queueSource = _requestCancellation(context, token);
          try {
            currentGeneration = await queueNext(advanceOnFailure: true, queueToken: queueSource.token);
          } on OperationCanceledException {
            if (token.isCancelled) {
              _reportStopped(context);
              break;
            }

            _reportTimedOut(context);
            host.markRequestCompleted();
            break;
          } catch (error) {
            _reportFailed(context, error);
            host.markRequestCompleted();
            continue;
          } finally {
            queueSource.dispose();
          }

          if (currentGeneration == null) {
            continue;
          }
        }

        final generation = currentGeneration;
        final alive = host.isCellAlive(generation.cell.id);
        if (alive) {
          host.setCellBusy(generation.cell.id, true);
        }

        final requestSource = _requestCancellation(context, token);
        try {
          token.throwIfCancelled();
          if (nextIndexToQueue < total && !_isStopRequested) {
            try {
              prefetched = await queueNext(advanceOnFailure: false, queueToken: requestSource.token);
            } on OperationCanceledException {
              rethrow;
            } catch (_) {
              // A failed prefetch must not cost the image that is already being generated.
              // The same cell is queued again once the current image has been collected.
            }
          }

          host.setStatus('Waiting for ComfyUI... (${generation.position}/$total)');
          final bytes = await client.waitForComfyImage(context.apiBaseUrl, generation.promptId, requestSource.token);
          outstandingPromptIds.remove(generation.promptId);
          requestSource.token.throwIfCancelled();
          await host.saveImage(generation.cell, bytes);
        } on OperationCanceledException {
          if (token.isCancelled) {
            _reportStopped(context);
            break;
          }

          _reportTimedOut(context);
          break;
        } catch (error) {
          _reportFailed(context, error);
        } finally {
          requestSource.dispose();
          if (alive) {
            host.setCellBusy(generation.cell.id, false);
          }

          host.markRequestCompleted();
        }
      }
    } finally {
      if (outstandingPromptIds.isNotEmpty) {
        final cleanup = CancellationSource(timeout: serverCleanupTimeout);
        try {
          await client.cancelComfyPrompts(context.apiBaseUrl, [...outstandingPromptIds], cleanup.token);
        } catch (_) {
          // Best effort cleanup.
        } finally {
          cleanup.dispose();
        }
      }
    }

    if (stoppedAfterRequestedImage) {
      host.report('Stopped after the last requested image in ${context.projectName}.', MessageSeverity.info);
    }
  }

  // -----------------------------------------------------------------------------------------------
  // Shared helpers
  // -----------------------------------------------------------------------------------------------

  int _skipRemovedCells(GenerationContext context, int nextIndex) {
    var index = nextIndex;
    while (index < context.targets.length && !host.isCellAlive(context.targets[index].id)) {
      _reportRemovedCell(context.targets[index]);
      index++;
    }

    return index;
  }

  void _reportRemovedCell(CellSnapshot cell) {
    host.report('Skipped ${cell.displayName} because the cell no longer exists.', MessageSeverity.warning);
    host.markRequestCompleted();
  }

  void _reportStopped(GenerationContext context) {
    host.report(
      host.forceInterruptRequested
          ? 'Generation force-stopped in ${context.projectName}.'
          : 'Generation interrupted in ${context.projectName}.',
      MessageSeverity.info,
    );
  }

  void _reportTimedOut(GenerationContext context) {
    host.report('Generation timed out in ${context.projectName}.', MessageSeverity.error);
  }

  void _reportFailed(GenerationContext context, Object error) {
    host.report('Generation failed in ${context.projectName}: ${SdClient.describeError(error)}', MessageSeverity.error);
  }

  static String ensureTaskId(GenerationRequest request) {
    final existing = request.forceTaskId;
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }

    final taskId = newTaskId(request.isImg2Img);
    request.forceTaskId = taskId;
    return taskId;
  }

  static String newTaskId(bool img2img) => 'task(multiplex-${img2img ? 'img2img' : 'txt2img'}-${newId()})';

  static int minimumRecoverablePixelCount(GenerationRequest request) =>
      request.enableHiresFix == true ? request.width * request.height + 1 : 0;

  static bool isRecoverableProxyError(Object error) {
    if (error is HttpStatusException) {
      return error.statusCode == 502 || error.statusCode == 504 || error.statusCode == 408 || error.statusCode == 524;
    }

    // A proxy that drops the connection before the final response surfaces as a client error.
    return error is http.ClientException;
  }

  static bool isGenerationIdle(ProgressResponse? progress) {
    if (progress == null) {
      return false;
    }

    if (progress.jobCount == 0) {
      return true;
    }

    if ((progress.job?.trim().isNotEmpty ?? false) || progress.jobCount > 0) {
      return false;
    }

    return progress.progress <= 0.0001 && progress.etaRelative <= 0;
  }

  static bool hasExpectedFinalPassStarted(ProgressResponse? progress, bool expectTwoPass) {
    if (!expectTwoPass) {
      return true;
    }

    return progress != null && progress.jobCount >= 2 && progress.jobNo >= 1;
  }

  static String buildWebUiProgressText(
    WebUiProgressSnapshot snapshot,
    int current,
    int total,
    String suffix,
    bool expectTwoPass,
  ) {
    final classic = snapshot.classic;
    final internal = snapshot.internal;
    final progress = snapshot.progressValue ?? 0;
    final passText = expectTwoPass && classic != null && classic.jobCount >= 2
        ? ' [Pass ${(classic.jobNo + 1).clamp(0, classic.jobCount)}/${classic.jobCount}]'
        : '';

    if (internal != null && internal.queued && !internal.active && !internal.completed) {
      return 'Queued in WebUI... ($current/$total)$suffix';
    }

    if (internal?.completed == true) {
      return 'Waiting for final image... ($current/$total)$passText$suffix';
    }

    if (progress > 0.001) {
      return 'Generating... ($current/$total) [${(progress * 100).toStringAsFixed(0)}%]$passText$suffix';
    }

    if (classic?.job?.trim().isNotEmpty ?? false) {
      return 'Preparing next pass... ($current/$total)$passText$suffix';
    }

    return 'Waiting for WebUI to finish... ($current/$total)$passText$suffix';
  }

  static String _describeDroppedResponse(WebUiRecoveryTracker tracker, bool expectTwoPass, String modeLabel) {
    final source = tracker.internalAvailable && tracker.classicAvailable
        ? '/internal/progress and /sdapi/v1/progress'
        : tracker.internalAvailable
        ? '/internal/progress'
        : tracker.classicAvailable
        ? '/sdapi/v1/progress'
        : 'the available progress APIs';

    if (expectTwoPass && !tracker.sawExpectedFinalPass) {
      return 'The proxy dropped the final image response before Hires.fix reached a recoverable second-pass preview image.';
    }

    return tracker.progressApiAvailable
        ? 'The proxy dropped the final image response, and $modeLabel could not recover a final preview from $source.'
        : 'The proxy dropped the final image response, and the progress APIs were not available for recovery.';
  }

  /// Builds the WebUI payload for [cell]; ComfyUI converts the same request into a workflow.
  ///
  /// In img2img jobs [source] is the cell's source image. Without it (e.g. for a preview) the
  /// request describes the img2img parameters but has no image, so it would run as txt2img.
  static GenerationRequest buildRequest(GenerationContext context, CellSnapshot cell, {Img2ImgSource? source}) {
    final img2img = context.isImg2Img;
    final steps = cell.overrideSteps ?? context.steps;
    final cfg = cell.overrideCfgScale ?? context.cfgScale;
    final sourceSized = img2img && context.useSourceImageSize && source != null;
    final width = cell.overrideWidth ?? (sourceSized ? roundGenerationDimension(source.width) : context.width);
    final height = cell.overrideHeight ?? (sourceSized ? roundGenerationDimension(source.height) : context.height);
    final prompt = PromptComposer.composePositivePrompt(context.globalCommonPrompt, context.commonPrompt, cell.prompt);
    final negative = PromptComposer.composeNegativePrompt(
      context.globalNegativePrompt,
      context.negativePrompt,
      cell.overrideNegativePrompt,
    );
    // Hires.fix is a txt2img feature; img2img requests ignore it.
    final hires = context.enableHiresFix && !img2img;
    final scheduler = context.scheduler.trim().isEmpty
        ? null
        : OptionLists.normalizeSchedulerForRequest(context.platform, context.scheduler);

    return GenerationRequest(
      prompt: context.platform.isWebUi ? applyWebUiLorasToPrompt(prompt, context.selectedLoras) : prompt,
      negativePrompt: negative.trim().isEmpty ? null : negative,
      clipSkip: context.clipSkip,
      steps: steps < 1 ? 1 : steps,
      cfgScale: cfg < 1 ? 1 : cfg,
      width: width < 64 ? 64 : width,
      height: height < 64 ? 64 : height,
      samplerName: context.samplerName.trim().isEmpty ? null : context.samplerName,
      scheduler: scheduler,
      selectedLoras: LoraSelection.normalize(context.selectedLoras),
      comfyLoraLoaderType: context.comfyLoraLoaderType,
      seed: context.seed,
      forceTaskId: context.platform.isWebUi ? newTaskId(img2img) : null,
      enableHiresFix: hires ? true : null,
      hiresScale: hires ? (context.hiresScale < 1 ? 1 : context.hiresScale) : null,
      hiresUpscaler: hires && context.hiresUpscaler.trim().isNotEmpty ? context.hiresUpscaler : null,
      hiresSteps: hires ? (context.hiresSteps < 0 ? 0 : context.hiresSteps) : null,
      hiresSamplerName: hires && context.samplerName.trim().isNotEmpty ? context.samplerName : null,
      hiresScheduler: hires ? scheduler : null,
      hiresDenoisingStrength: hires ? context.hiresDenoisingStrength.clamp(0.0, 1.0).toDouble() : null,
      hiresResizeX: hires ? (context.hiresResizeWidth < 0 ? 0 : context.hiresResizeWidth) : null,
      hiresResizeY: hires ? (context.hiresResizeHeight < 0 ? 0 : context.hiresResizeHeight) : null,
      sdModelCheckpoint: context.checkpointModel.trim().isEmpty ? null : context.checkpointModel,
      clipStopAtLastLayers: context.clipSkip > 0 ? context.clipSkip : null,
      source: img2img ? source : null,
      denoisingStrength: (cell.overrideDenoisingStrength ?? context.denoisingStrength).clamp(0.0, 1.0).toDouble(),
      resizeMode: context.resizeMode,
    );
  }

  /// Appends `<lora:name:weight>` tags for the selected LoRAs, replacing tags for the same LoRA that
  /// the prompt already contains.
  static String applyWebUiLorasToPrompt(String prompt, List<LoraSelection> loras) {
    final normalized = LoraSelection.normalize(loras);
    var effective = prompt;
    for (final lora in normalized) {
      effective = effective.replaceAll(
        RegExp(r'\s*<\s*lora\s*:\s*' + RegExp.escape(lora.name) + r'\s*:\s*[^>]+>', caseSensitive: false),
        '',
      );
    }

    effective = effective.trim();
    if (normalized.isEmpty) {
      return effective;
    }

    final tags = normalized.map((lora) => '<lora:${lora.name}:${LoraSelection.formatWeight(lora.weight)}>').join('\n');
    return effective.isEmpty ? tags : '$effective\n$tags';
  }
}

/// One poll of the WebUI progress APIs.
class WebUiProgressSnapshot {
  const WebUiProgressSnapshot(this.internal, this.classic);

  final InternalProgressResponse? internal;
  final ProgressResponse? classic;

  bool get internalAvailable => internal != null;
  bool get classicAvailable => classic != null;

  double? get progressValue {
    final value = internal?.progress ?? classic?.progress;
    return value == null || value <= 0 ? null : value.clamp(0.0, 1.0);
  }
}

/// Remembers the best preview seen while polling so a dropped final response can still produce an
/// image (with Hires.fix only previews from the second pass qualify).
class WebUiRecoveryTracker {
  WebUiRecoveryTracker(int minimumAcceptablePixelCount)
    : _minimumPixels = minimumAcceptablePixelCount < 0 ? 0 : minimumAcceptablePixelCount;

  final int _minimumPixels;
  int lastInternalLivePreviewId = -1;
  String? bestRecoverableImage;
  bool sawExpectedFinalPass = false;
  bool internalAvailable = false;
  bool classicAvailable = false;

  bool get progressApiAvailable => internalAvailable || classicAvailable;

  void observe(WebUiProgressSnapshot snapshot, bool expectTwoPass) {
    internalAvailable |= snapshot.internalAvailable;
    classicAvailable |= snapshot.classicAvailable;

    final internal = snapshot.internal;
    if (internal != null && internal.livePreviewId >= 0 && internal.livePreviewId > lastInternalLivePreviewId) {
      lastInternalLivePreviewId = internal.livePreviewId;
    }

    final finalPassStarted = GenerationRunner.hasExpectedFinalPassStarted(snapshot.classic, expectTwoPass);
    if (internal?.completed == true || finalPassStarted) {
      sawExpectedFinalPass = true;
    }

    final candidate = (internal?.livePreview?.trim().isNotEmpty ?? false)
        ? internal!.livePreview
        : snapshot.classic?.currentImage;
    if (candidate == null || candidate.trim().isEmpty) {
      return;
    }

    final canUse =
        !expectTwoPass ||
        internal?.completed == true ||
        finalPassStarted ||
        GenerationRunner.isGenerationIdle(snapshot.classic);
    if (!canUse) {
      return;
    }

    final candidateMetrics = _metrics(candidate);
    if (_minimumPixels > 0 && candidateMetrics.pixels < _minimumPixels) {
      return;
    }

    final currentMetrics = _metrics(bestRecoverableImage);
    if (candidateMetrics.pixels > currentMetrics.pixels ||
        (candidateMetrics.pixels == currentMetrics.pixels && candidateMetrics.length > currentMetrics.length)) {
      bestRecoverableImage = candidate;
    }
  }

  static ({int pixels, int length}) _metrics(String? image) {
    if (image == null || image.trim().isEmpty) {
      return (pixels: 0, length: 0);
    }

    final payload = ImageSignature.stripDataUriPrefix(image);
    final bytes = ImageSignature.tryDecodeBase64(payload);
    final size = bytes == null ? null : ImageSignature.tryReadPngSize(bytes);
    return (pixels: size == null ? 0 : size.width * size.height, length: payload.length);
  }
}

class _AgentQueued {
  _AgentQueued(this.cell, this.request, this.queueTaskId, this.forcedTaskId, this.position);

  final CellSnapshot cell;
  final GenerationRequest request;
  final String queueTaskId;
  final String forcedTaskId;
  final int position;
}

class _ComfyQueued {
  _ComfyQueued(this.cell, this.promptId, this.position);

  final CellSnapshot cell;
  final String promptId;
  final int position;
}
