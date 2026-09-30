import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:multiplex/src/models/api_platform.dart';
import 'package:multiplex/src/models/img2img.dart';
import 'package:multiplex/src/services/png_metadata_reader.dart';
import 'package:multiplex/src/services/project_transfer.dart';
import 'package:multiplex/src/state/project_session.dart';
import 'package:path/path.dart' as p;

import '../support/fake_sd_server.dart';
import '../support/test_app.dart';

/// Writes a solid-colour PNG outside the project, like a file the user picks.
Future<String> writeSourceFile(Directory folder, String name, {int width = 320, int height = 200}) async {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 40, 40));
  final file = File(p.join(folder.path, name));
  await file.writeAsBytes(img.encodePng(image));
  return file.path;
}

void main() {
  late FakeSdServer server;
  late TestApp testApp;
  late Directory picked;

  ProjectSession session() => testApp.app.selected!;

  Future<ProjectSession> setUpImg2Img({FakeSdServer? fake, bool projectSource = true}) async {
    server = fake ?? FakeSdServer();
    testApp = await createTestApp(server);
    picked = await Directory.systemTemp.createTemp('multiplex-picked-');
    final project = session()..setGenerationType(GenerationType.img2img);
    for (var index = 0; index < project.cells.length; index++) {
      project.cells[index].prompt = 'subject ${index + 1}';
    }

    if (projectSource) {
      await project.setProjectSourceImage(await writeSourceFile(picked, 'photo.png'));
    }

    return project;
  }

  tearDown(() async {
    await testApp.dispose();
    await picked.delete(recursive: true);
  });

  Future<void> waitForIdle() => waitFor(() => !session().generation.hasWork);

  test('WebUI img2img sends the source image and uses its size', () async {
    final project = await setUpImg2Img();
    project
      ..edit((settings) {
        settings
          ..denoisingStrength = 0.4
          ..resizeMode = Img2ImgResizeModes.cropAndResize
          // Hires.fix is a txt2img feature and must not leak into img2img requests.
          ..enableHiresFix = true;
      })
      ..cells[0].isSelected = true
      ..cells[1].isSelected = true;
    project.cells[1].setDenoisingOverride(0.9);

    project.generate();
    await waitForIdle();

    expect(server.txt2imgRequests, isEmpty);
    expect(server.img2imgRequests, hasLength(2), reason: testApp.messageTexts.join('\n'));
    final first = server.img2imgRequests.first;
    final stored = await File(project.projectSourceImagePath!).readAsBytes();
    expect(base64.decode((first['init_images']! as List).single! as String), stored);
    expect(first['denoising_strength'], 0.4);
    expect(first['resize_mode'], 1);
    expect([first['width'], first['height']], [320, 200]);
    expect(first.containsKey('enable_hr'), isFalse);
    expect(first['force_task_id'], startsWith('task(multiplex-img2img-'));
    expect(server.img2imgRequests[1]['denoising_strength'], 0.9);

    final image = (await project.listImages(project.cells.first)).single;
    final metadata = await PngMetadataReader.readFile(image.path);
    expect(metadata.isImg2Img, isTrue);
    expect(metadata.denoisingStrength, 0.4);
    expect(metadata.enableHiresFix, isNot(isTrue));
  });

  test('cells use their own source image and cells without one are reported', () async {
    final project = await setUpImg2Img(projectSource: false);
    await project.setCellSourceImage(
      project.cells[2],
      await writeSourceFile(picked, 'own.png', width: 256, height: 384),
    );
    expect(project.cellsWithoutSource(project.cells), hasLength(3));

    project.generate();
    await waitForIdle();

    expect(server.img2imgRequests.map((request) => request['prompt']), ['subject 3']);
    expect([server.img2imgRequests.single['width'], server.img2imgRequests.single['height']], [256, 384]);
    expect(
      testApp.messageTexts.where((message) => message.contains('has no source image')),
      hasLength(3),
      reason: testApp.messageTexts.join('\n'),
    );
  });

  test('custom size and cell size overrides win over the source size', () async {
    final project = await setUpImg2Img();
    project.edit((settings) {
      settings
        ..useSourceImageSize = false
        ..width = 512
        ..height = 768;
    });
    project.cells[1].setOverrides(steps: null, cfgScale: null, width: 640, height: null, negativePrompt: '');
    project
      ..cells[0].isSelected = true
      ..cells[1].isSelected = true
      ..generate();
    await waitForIdle();

    expect([server.img2imgRequests[0]['width'], server.img2imgRequests[0]['height']], [512, 768]);
    expect([server.img2imgRequests[1]['width'], server.img2imgRequests[1]['height']], [640, 768]);
  });

  test('Agent Scheduler queues img2img tasks and collects the results', () async {
    final project = await setUpImg2Img();
    project.edit((settings) => settings.generationMode = GenerationModes.agentScheduler);
    project.generate();
    await waitForIdle();

    expect(server.log.where((entry) => entry == 'POST /agent-scheduler/v1/queue/img2img'), hasLength(4));
    expect(server.img2imgRequests.every((request) => request['init_images'] != null), isTrue);
    for (final cell in project.cells) {
      expect(await project.listImages(cell), hasLength(1), reason: testApp.messageTexts.join('\n'));
    }
  });

  test('ComfyUI img2img uploads each source once per job and encodes it', () async {
    final project = await setUpImg2Img();
    project
      ..setPlatform(ApiPlatform.comfyUi)
      ..edit((settings) => settings.resizeMode = Img2ImgResizeModes.resizeAndFill);
    await project.setCellSourceImage(project.cells[3], await writeSourceFile(picked, 'other.png'));
    project.generateRepeatCount = 2;
    project.generate();
    await waitForIdle();

    // Two different source images, uploaded once each although eight prompts use them.
    expect(server.log.where((entry) => entry == 'POST /upload/image'), hasLength(2));
    expect(server.comfyInputs.keys, everyElement(startsWith('multiplex-source-')));
    expect(server.comfyPrompts, hasLength(8));
    final types = server.comfyPrompts.first.values.cast<Map<String, Object?>>().map((node) => node['class_type']);
    expect(types, containsAll(['LoadImage', 'ImageScale', 'VAEEncode']));
    expect(types, isNot(contains('EmptyLatentImage')));

    final image = (await project.listImages(project.cells.first)).first;
    final metadata = await PngMetadataReader.readFile(image.path);
    expect(metadata.metadataSource, 'ComfyUI prompt graph');
    expect(metadata.isImg2Img, isTrue);
    expect(metadata.denoisingStrength, Img2ImgDefaults.denoisingStrength);
  });

  test('source images are copied into the project and unused copies are removed', () async {
    final project = await setUpImg2Img();
    final first = project.projectSourceImagePath!;
    expect(p.isWithin(project.sourceFolder, first), isTrue);
    expect(project.settings.sourceImagePath, startsWith('sources/source-'));

    await project.setProjectSourceImage(await writeSourceFile(picked, 'second.png'));
    await project.pruneSourceImages();
    expect(File(first).existsSync(), isFalse);
    expect(Directory(project.sourceFolder).listSync(), hasLength(1));

    final notAnImage = File(p.join(picked.path, 'notes.png'))..writeAsStringSync('not an image');
    await expectLater(project.setProjectSourceImage(notAnImage.path), throwsFormatException);

    await project.setProjectSourceImage(null);
    await project.pruneSourceImages();
    expect(project.projectSourceImagePath, isNull);
    expect(Directory(project.sourceFolder).listSync(), isEmpty);
  });

  test('exports carry source images and imports restore them', () async {
    final project = await setUpImg2Img();
    await project.setCellSourceImage(project.cells[1], await writeSourceFile(picked, 'cell.png'));
    project.cells[1].setDenoisingOverride(0.3);
    await project.saveNow();

    final json = ProjectTransfer.serializeProject(project.snapshot(), sourceImages: await project.readSourceImages());
    final decoded = jsonDecode(json) as Map<String, Object?>;
    expect((decoded['SourceImages']! as Map).keys, hasLength(2));
    expect((decoded['Settings']! as Map)['GenerationType'], 'img2img');

    expect(await testApp.app.importProjects(json), 1);
    final imported = testApp.app.projects.firstWhere((candidate) => candidate.id != project.id);
    expect(imported.isImg2Img, isTrue);
    expect(
      File(imported.projectSourceImagePath!).readAsBytesSync(),
      File(project.projectSourceImagePath!).readAsBytesSync(),
    );
    expect(p.isWithin(imported.projectFolder, imported.cells[1].sourceImagePath!), isTrue);
    expect(File(imported.cells[1].sourceImagePath!).existsSync(), isTrue);
    expect(imported.cells[1].overrideDenoisingStrength, 0.3);
  });

  test('cloning a project copies its source images', () async {
    final project = await setUpImg2Img();
    await project.saveNow();
    final clone = (await testApp.app.cloneProject(project))!;
    expect(clone.projectSourceImagePath, isNot(project.projectSourceImagePath));
    expect(File(clone.projectSourceImagePath!).existsSync(), isTrue);
  });
}
