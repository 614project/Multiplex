import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:multiplex/src/models/api_platform.dart';
import 'package:multiplex/src/models/lora_selection.dart';
import 'package:multiplex/src/services/png_metadata_reader.dart';
import 'package:multiplex/src/state/project_session.dart';

import '../support/fake_sd_server.dart';
import '../support/test_app.dart';

void main() {
  late FakeSdServer server;
  late TestApp testApp;

  ProjectSession session() => testApp.app.selected!;

  Future<void> setUpApp({FakeSdServer? fake, Map<String, Object?> preferences = const {}}) async {
    server = fake ?? FakeSdServer();
    testApp = await createTestApp(server, preferences: preferences);
    final project = session();
    for (var index = 0; index < project.cells.length; index++) {
      project.cells[index].prompt = 'subject ${index + 1}';
    }
  }

  tearDown(() async => testApp.dispose());

  Future<void> waitForIdle() => waitFor(() => !session().generation.hasWork);

  Future<int> imageCount(ProjectSession project) async {
    var count = 0;
    for (final cell in project.cells) {
      count += (await project.listImages(cell)).length;
    }

    return count;
  }

  test('generates every cell in round-robin order and stores the images', () async {
    await setUpApp(preferences: {'globalCommonPrompt': 'masterpiece'});
    final project = session()
      ..edit((settings) {
        settings.commonPrompt = 'best quality, <CELL_PROMPT>, detailed';
        settings.selectedLoras = const [LoraSelection(name: 'style-a', weight: 0.7)];
        settings.checkpointModel = FakeSdServer.checkpoints[1];
        settings.clipSkip = 2;
      })
      ..generateRepeatCount = 2;
    project.cells[1].setOverrides(steps: 30, cfgScale: null, width: 640, height: null, negativePrompt: 'blurry');

    final job = project.generate();
    expect(job, isNotNull);
    expect(job!.totalImages, 8);
    await waitForIdle();

    expect(server.txt2imgRequests, hasLength(8));
    final prompts = server.txt2imgRequests.map((request) => (request['prompt']! as String).split('\n').first).toList();
    expect(prompts.take(4), [
      for (var index = 1; index <= 4; index++) 'masterpiece,best quality, subject $index, detailed',
    ]);
    expect(prompts.skip(4), prompts.take(4));
    expect(server.txt2imgRequests.first['prompt'], endsWith('<lora:style-a:0.7>'));
    expect(server.txt2imgRequests.first['override_settings'], {
      'sd_model_checkpoint': FakeSdServer.checkpoints[1],
      'CLIP_stop_at_last_layers': 2,
    });
    expect(server.txt2imgRequests[1]['steps'], 30);
    expect(server.txt2imgRequests[1]['width'], 640);
    expect(server.txt2imgRequests[1]['negative_prompt'], 'blurry');
    expect(server.txt2imgRequests[0]['steps'], 20);

    for (final cell in project.cells) {
      final images = await project.listImages(cell);
      expect(images, hasLength(2));
      expect(cell.lastImagePath, images.first.path);
      expect(cell.displayImagePath, images.first.path);
    }

    expect(job.completedImages, 8);
    expect(project.generation.statusText, 'Ready');

    final metadata = await PngMetadataReader.readFile(project.cells.first.lastImagePath!);
    expect(metadata.metadataSource, 'WebUI PNG parameters');
    expect(metadata.positivePrompt, contains('subject 1'));
    expect(metadata.loras, ['style-a']);
    expect(metadata.checkpoint, FakeSdServer.checkpoints[1]);
    expect(metadata.clipSkip, 2);
  });

  test('generates only the selected cells', () async {
    await setUpApp();
    final project = session();
    project.cells[0].isSelected = true;
    project.cells[2].isSelected = true;
    expect(project.cellSelectionSummary, '2 cells selected');

    project.generate();
    await waitForIdle();

    expect(server.txt2imgRequests.map((request) => request['prompt']), ['subject 1', 'subject 3']);
  });

  test('the first interrupt stops after the requested image', () async {
    await setUpApp(fake: FakeSdServer(generationTime: const Duration(milliseconds: 400)));
    final project = session()..generate();
    await waitFor(() => project.cells.first.isBusy);
    await project.interrupt();
    expect(project.generation.stopAfterCurrentImageRequested, isTrue);
    await waitForIdle();

    expect(server.txt2imgRequests, hasLength(1));
    expect(await imageCount(project), 1);
    expect(testApp.messageTexts, contains(contains('Stopped after the last requested image')));
  });

  test('the second interrupt force-stops the job and the queue continues', () async {
    await setUpApp(fake: FakeSdServer(generationTime: const Duration(milliseconds: 600)));
    final project = session();
    project.generate();
    final second = project.regenerate(project.cells.last)!;
    expect(project.generation.pending.single, second);
    expect(second.status, 'Queued (1)');

    await waitFor(() => project.cells.first.isBusy);
    await project.interrupt();
    await project.interrupt();
    expect(server.interruptCount, 1);
    await waitForIdle();

    expect(testApp.messageTexts, contains('Generation force-stopped in ${project.name}.'));
    // The force-stopped job produced nothing; the queued regenerate job still ran.
    expect(server.txt2imgRequests.last['prompt'], 'subject 4');
    expect((await project.listImages(project.cells.last)), hasLength(1));
  });

  test('queued jobs can be removed before they start', () async {
    await setUpApp(fake: FakeSdServer(generationTime: const Duration(milliseconds: 300)));
    final project = session();
    project.regenerate(project.cells[0]);
    final removed = project.regenerate(project.cells[1])!;
    project.regenerate(project.cells[2]);
    project.removeQueuedJob(removed);
    await waitForIdle();

    expect(server.txt2imgRequests.map((request) => request['prompt']), ['subject 1', 'subject 3']);
  });

  test('polling mode recovers the final preview when the proxy drops the response', () async {
    await setUpApp(
      fake: FakeSdServer(dropFinalGenerationResponse: true, generationTime: const Duration(milliseconds: 300)),
    );
    final project = session()..edit((settings) => settings.generationMode = 'Polling (Proxy Safe)');
    project.regenerate(project.cells.first);
    await waitForIdle();

    final images = await project.listImages(project.cells.first);
    expect(images, hasLength(1), reason: testApp.messageTexts.join('\n'));
    final metadata = await PngMetadataReader.readFile(images.single.path);
    expect(metadata.width, 64);
  });

  test('standard mode reports a dropped response as a failure', () async {
    await setUpApp(fake: FakeSdServer(dropFinalGenerationResponse: true), preferences: {'livePreviewEnabled': false});
    final project = session();
    project.regenerate(project.cells.first);
    await waitForIdle();

    expect(await imageCount(project), 0);
    expect(testApp.messageTexts.last, contains('HTTP 504'));
  });

  test('Agent Scheduler mode queues tasks and collects every result', () async {
    await setUpApp();
    final project = session()..edit((settings) => settings.generationMode = 'Agent Scheduler');
    project.generate();
    await waitForIdle();

    expect(server.txt2imgRequests, hasLength(4));
    expect(await imageCount(project), 4, reason: testApp.messageTexts.join('\n'));
    expect(server.log, contains('POST /agent-scheduler/v1/queue/txt2img'));
  });

  test('ComfyUI mode builds workflows, prefetches and stores the graph in the image', () async {
    await setUpApp();
    final project = session()..setPlatform(ApiPlatform.comfyUi);
    expect(project.settings.samplerName, 'euler');
    project.edit((settings) {
      settings.selectedLoras = const [LoraSelection(name: 'style-a.safetensors', weight: 0.6)];
      settings.enableHiresFix = true;
      settings.clipSkip = 2;
    });
    project.cells[1].isSelected = true;
    project.cells[3].isSelected = true;
    project.generate();
    await waitForIdle();

    expect(server.comfyPrompts, hasLength(2));
    expect(server.log.where((entry) => entry == 'GET /object_info'), hasLength(1));
    final images = await project.listImages(project.cells[1]);
    expect(images, hasLength(1), reason: testApp.messageTexts.join('\n'));
    final metadata = await PngMetadataReader.readFile(images.single.path);
    expect(metadata.metadataSource, 'ComfyUI prompt graph');
    expect(metadata.positivePrompt, 'subject 2');
    expect(metadata.enableHiresFix, isTrue);
    expect(metadata.clipSkip, 2);
    expect(metadata.loras, ['style-a.safetensors']);
    expect(metadata.checkpoint, FakeSdServer.checkpoints.first);
  });

  test('ComfyUI force stop removes our queued prompts from the server', () async {
    await setUpApp(fake: FakeSdServer(generationTime: const Duration(milliseconds: 500)));
    final project = session()..setPlatform(ApiPlatform.comfyUi);
    project.generate();
    await waitFor(() => server.comfyPrompts.length >= 2);
    await project.interrupt();
    await project.interrupt();
    await waitForIdle();

    expect(server.log, contains('POST /queue'));
    expect(server.log, contains('POST /interrupt'));
    expect(await imageCount(project), 0);
  });

  test('a cell removed while queued is skipped', () async {
    await setUpApp(fake: FakeSdServer(generationTime: const Duration(milliseconds: 200)));
    final project = session()..generate();
    await waitFor(() => project.cells.first.isBusy);
    project.removeCells([project.cells[2]]);
    await waitForIdle();

    expect(server.txt2imgRequests.map((request) => request['prompt']), ['subject 1', 'subject 2', 'subject 4']);
    expect(testApp.messageTexts, contains(contains('because the cell no longer exists')));
  });

  test('a timed out request is reported and the next job waits for WebUI to go idle', () async {
    await setUpApp(fake: FakeSdServer(generationTime: const Duration(seconds: 3)));
    final project = session()..edit((settings) => settings.timeoutSeconds = 1);
    project.regenerate(project.cells.first);
    await waitForIdle();

    expect(testApp.messageTexts, contains('Generation timed out in ${project.name}.'));
    expect(project.waitForWebUiIdle, isTrue);
  });

  test('projects are saved and restored with their cells and images', () async {
    await setUpApp();
    final project = session();
    project.rename('Renamed project');
    project.edit((settings) => settings.steps = 33);
    project.regenerate(project.cells.first);
    await waitForIdle();
    await testApp.app.flush();

    final restored = await testApp.app.store.load(project.id);
    expect(restored.metadata.name, 'Renamed project');
    expect(restored.settings.steps, 33);
    expect(restored.cells.first.lastImagePath, startsWith('cells/${project.cells.first.id}/'));
    expect(File('${project.projectFolder}/${restored.cells.first.lastImagePath}').existsSync(), isTrue);
  });

  test('checkpoints and LoRAs are listed from the server', () async {
    await setUpApp();
    final project = session()..setCheckpoint('missing.safetensors');
    final checkpoints = await project.fetchCheckpoints();
    expect(checkpoints.first, 'missing.safetensors');
    expect(checkpoints, containsAll(FakeSdServer.checkpoints));
    final loras = await project.fetchLoras();
    expect(loras.names, FakeSdServer.loras);
  });

  test('server metadata replaces the fallback option lists', () async {
    await setUpApp();
    final project = session();
    await waitFor(() => project.serverStatus == ServerStatus.online);
    await waitFor(() => project.samplerOptions.contains('DPM++ SDE'));
    expect(project.serverMessage, contains(FakeSdServer.checkpoints.first));
    expect(project.schedulerOptions, contains('Karras'));
    expect(project.hiresUpscalerOptions, contains('R-ESRGAN 4x+'));
  });
}
