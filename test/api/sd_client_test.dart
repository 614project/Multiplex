import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:multiplex/src/api/comfy_workflow.dart';
import 'package:multiplex/src/api/sd_client.dart';
import 'package:multiplex/src/api/sd_models.dart';
import 'package:multiplex/src/core/cancellation.dart';
import 'package:multiplex/src/models/api_platform.dart';
import 'package:multiplex/src/models/lora_selection.dart';

import '../support/recording_client.dart';

const comfyUrl = 'http://127.0.0.1:8188';
const webUiUrl = 'http://127.0.0.1:7860';

const metadata = ComfyObjectInfoMetadata(
  checkpointNames: ['model.safetensors'],
  samplerNames: ['euler'],
  schedulerNames: ['normal'],
  latentUpscaleMethods: ['bislerp'],
  availableLoraLoaderTypes: ['LoraLoader'],
  supportsClipSetLastLayer: true,
);

Txt2ImgRequest createRequest() =>
    Txt2ImgRequest(prompt: 'a cat', steps: 20, cfgScale: 7, width: 512, height: 512, seed: 42);

void main() {
  final none = CancellationToken.none;

  group('ComfyUI response parsing', () {
    test('reads legacy combo options', () {
      expect(
        SdClient.extractComfyComboValues(jsonDecode('[["a.safetensors", "b.safetensors"], {"tooltip": "model"}]')),
        ['a.safetensors', 'b.safetensors'],
      );
    });

    test('reads V3 combo with a single option', () {
      expect(
        SdClient.extractComfyComboValues(
          jsonDecode('["COMBO", {"options": ["only.safetensors"], "tooltip": "model"}]'),
        ),
        ['only.safetensors'],
      );
    });

    test('V3 combo without options has no values', () {
      expect(SdClient.extractComfyComboValues(jsonDecode('["COMBO", {"remote": {"route": "/models"}}]')), isEmpty);
      expect(SdClient.extractComfyComboValues(jsonDecode('["COMBO", {"options": []}]')), isEmpty);
    });

    test('builds metadata from object_info', () {
      final parsed = SdClient.parseObjectInfo(
        jsonDecode('''
        {
          "CheckpointLoaderSimple": { "input": { "required": { "ckpt_name": ["COMBO", { "options": ["only.safetensors"] }] } } },
          "KSampler": { "input": { "required": {
            "sampler_name": [["euler", "euler_ancestral"], {}],
            "scheduler": [["normal", "karras"], {}] } } },
          "LatentUpscaleBy": { "input": { "required": { "upscale_method": [["nearest-exact", "bislerp"], {}] } } },
          "LoraLoader": { "input": { "required": { "lora_name": ["COMBO", { "options": ["style.safetensors"] }] } } },
          "CLIPSetLastLayer": { "input": { "required": {} } }
        }
      '''),
      );
      expect(parsed.checkpointNames, ['only.safetensors']);
      expect(parsed.samplerNames, ['euler', 'euler_ancestral']);
      expect(parsed.schedulerNames, ['normal', 'karras']);
      expect(parsed.latentUpscaleMethods, ['nearest-exact', 'bislerp']);
      expect(parsed.loraNames, ['style.safetensors']);
      expect(parsed.availableLoraLoaderTypes, ['LoraLoader']);
      expect(parsed.supportsClipSetLastLayer, isTrue);
    });

    test('describes a rejected workflow', () {
      final message = SdClient.buildComfyPromptErrorMessage(
        jsonDecode('''
        {
          "error": { "type": "prompt_outputs_failed_validation", "message": "Prompt outputs failed validation", "details": "", "extra_info": {} },
          "node_errors": {
            "3": {
              "errors": [ { "type": "value_not_in_list", "message": "Value not in list", "details": "ckpt_name: 'missing.safetensors' not in []" } ],
              "class_type": "CheckpointLoaderSimple"
            }
          }
        }
      '''),
      );
      expect(message, contains('Prompt outputs failed validation'));
      expect(
        message,
        contains("CheckpointLoaderSimple (node 3): Value not in list (ckpt_name: 'missing.safetensors' not in [])"),
      );
    });

    test('accepted workflow has no error message', () {
      expect(
        SdClient.buildComfyPromptErrorMessage(jsonDecode('{ "prompt_id": "abc", "number": 3, "node_errors": {} }')),
        isNull,
      );
    });

    test('reads the execution error from history messages', () {
      final record = jsonDecode('''
        { "outputs": {}, "status": { "status_str": "error", "completed": false, "messages": [
          ["execution_start", { "prompt_id": "p" }],
          ["execution_error", { "prompt_id": "p", "node_type": "KSampler", "exception_message": "CUDA out of memory" }]
        ] } }
      ''') as Map<String, Object?>;
      expect(SdClient.tryGetComfyPromptError(record), 'KSampler: CUDA out of memory');
    });

    test('reports an interrupted prompt', () {
      final record = jsonDecode(
        '{ "status": { "status_str": "error", "completed": false, "messages": [["execution_interrupted", { "prompt_id": "p" }]] } }',
      ) as Map<String, Object?>;
      expect(SdClient.tryGetComfyPromptError(record), 'ComfyUI interrupted the prompt.');
    });

    test('successful history has no error', () {
      final record = jsonDecode(
        '{ "status": { "status_str": "success", "completed": true, "messages": [] } }',
      ) as Map<String, Object?>;
      expect(SdClient.tryGetComfyPromptError(record), isNull);
    });

    test('detects finished history records', () {
      Map<String, Object?> parse(String json) => jsonDecode(json) as Map<String, Object?>;
      expect(
        SdClient.isComfyHistoryRecordFinished(
          parse('{ "outputs": {}, "status": { "status_str": "success", "completed": true } }'),
        ),
        isTrue,
      );
      expect(SdClient.isComfyHistoryRecordFinished(parse('{ "outputs": {} }')), isTrue);
      expect(
        SdClient.isComfyHistoryRecordFinished(
          parse('{ "outputs": {}, "status": { "status_str": "running", "completed": false } }'),
        ),
        isFalse,
      );
    });

    test('finds only our running prompt', () {
      final queue = jsonDecode(
        '{ "queue_running": [[7, "ours", {}, {}, []]], "queue_pending": [[8, "later", {}, {}, []]] }',
      );
      expect(SdClient.findRunningComfyPromptId(queue, ['later', 'ours']), 'ours');
      expect(SdClient.findRunningComfyPromptId(queue, ['later']), isNull);
    });

    test('reads the Agent Scheduler task status', () {
      expect(SdClient.readAgentSchedulerTaskStatus(jsonDecode('{ "id": "t", "status": "pending" }')), 'pending');
      expect(
        SdClient.readAgentSchedulerTaskStatus(
          jsonDecode('{ "success": true, "data": { "id": "t", "status": "running" } }'),
        ),
        'running',
      );
      expect(SdClient.readAgentSchedulerTaskStatus(jsonDecode('{ "id": "t" }')), isNull);
    });
  });

  group('SdClient', () {
    test('cancelling ComfyUI prompts deletes queued ones and interrupts only our running prompt', () async {
      final recorder = RecordingClient(
        (request) => request.method == 'GET' && request.uri.path == '/queue'
            ? RecordingClient.json('{ "queue_running": [[1, "ours-running", {}, {}, []]], "queue_pending": [] }')
            : RecordingClient.json('{}'),
      );
      final client = SdClient(httpClient: recorder.client);

      await client.cancelComfyPrompts(comfyUrl, ['ours-running', 'ours-pending'], none);

      expect(recorder.requests.map((request) => request.summary), ['POST /queue', 'GET /queue', 'POST /interrupt']);
      expect(recorder.requests[0].body, contains('"delete":["ours-running","ours-pending"]'));
      expect(recorder.requests[2].body, '{"prompt_id":"ours-running"}');
    });

    test('cancelling ComfyUI prompts does not interrupt someone else\'s prompt', () async {
      final recorder = RecordingClient(
        (request) => request.method == 'GET'
            ? RecordingClient.json('{ "queue_running": [[1, "other-client", {}, {}, []]], "queue_pending": [] }')
            : RecordingClient.json('{}'),
      );
      await SdClient(httpClient: recorder.client).cancelComfyPrompts(comfyUrl, ['ours'], none);
      expect(recorder.requests.map((request) => request.summary), isNot(contains('POST /interrupt')));
    });

    test('queueing with known metadata does not fetch object_info', () async {
      final recorder = RecordingClient(
        (_) => RecordingClient.json('{ "prompt_id": "server-id", "number": 1, "node_errors": {} }'),
      );
      final promptId = await SdClient(httpClient: recorder.client)
          .queueComfyTxt2Img(comfyUrl, createRequest(), metadata, none, clientId: 'client');

      expect(promptId, 'server-id');
      expect(recorder.requests.single.summary, 'POST /prompt');
      expect(recorder.requests.single.body, contains('"ckpt_name":"model.safetensors"'));
    });

    test('a rejected workflow reports the failing node', () async {
      final recorder = RecordingClient(
        (_) => RecordingClient.json(
          '{ "error": { "message": "Prompt outputs failed validation", "details": "" }, "node_errors": { "3": { "class_type": "KSampler", "errors": [ { "message": "Value not in list", "details": "sampler_name: \'nope\'" } ] } } }',
          400,
        ),
      );
      await expectLater(
        SdClient(httpClient: recorder.client)
            .queueComfyTxt2Img(comfyUrl, createRequest(), metadata, none, clientId: 'c'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains("KSampler (node 3): Value not in list (sampler_name: 'nope')"),
          ),
        ),
      );
    });

    test('a finished prompt without an image fails instead of polling until the timeout', () async {
      final recorder = RecordingClient(
        (_) => RecordingClient.json(
          '{ "p1": { "outputs": {}, "status": { "status_str": "success", "completed": true, "messages": [] } } }',
        ),
      );
      await expectLater(
        SdClient(httpClient: recorder.client).waitForComfyImage(comfyUrl, 'p1', none),
        throwsA(
          isA<ApiException>().having((error) => error.message, 'message', contains('without producing an image')),
        ),
      );
      expect(recorder.requests, hasLength(1));
    });

    test('downloads the image of a finished prompt', () async {
      final imageBytes = [0x89, 0x50, 0x4E, 0x47, 1, 2, 3];
      final recorder = RecordingClient(
        (request) => request.uri.path == '/view'
            ? http.Response.bytes(imageBytes, 200)
            : RecordingClient.json(
                '{ "p1": { "outputs": { "9": { "images": [ { "filename": "out.png", "subfolder": "", "type": "output" } ] } }, "status": { "status_str": "success", "completed": true } } }',
              ),
      );
      final bytes = await SdClient(httpClient: recorder.client).waitForComfyImage(comfyUrl, 'p1', none);
      expect(bytes, imageBytes);
      expect(recorder.requests.last.summary, 'GET /view?filename=out.png&type=output');
    });

    test('finished Agent Scheduler tasks are not deleted', () async {
      final recorder = RecordingClient((_) => RecordingClient.json('{ "id": "t1", "status": "done" }'));
      await SdClient(httpClient: recorder.client).cancelAgentSchedulerTask(webUiUrl, 't1', none);
      expect(recorder.requests.single.summary, 'GET /agent-scheduler/v1/task/t1');
    });

    test('pending Agent Scheduler tasks are deleted', () async {
      final recorder = RecordingClient(
        (request) => request.method == 'GET'
            ? RecordingClient.json('{ "id": "t1", "status": "pending" }')
            : RecordingClient.json('{ "success": true }'),
      );
      await SdClient(httpClient: recorder.client).cancelAgentSchedulerTask(webUiUrl, 't1', none);
      expect(recorder.requests.map((request) => request.summary), [
        'GET /agent-scheduler/v1/task/t1',
        'POST /agent-scheduler/v1/task/t1/delete',
      ]);
    });

    test('Agent Scheduler delete falls back to the legacy route', () async {
      final recorder = RecordingClient(
        (request) => switch (request.uri.path) {
          '/agent-scheduler/v1/task/t1' => RecordingClient.json('{ "status": "running" }'),
          '/agent-scheduler/v1/task/t1/delete' => RecordingClient.json('{ "detail": "Not Found" }', 404),
          _ => RecordingClient.json('{ "success": true }'),
        },
      );
      await SdClient(httpClient: recorder.client).cancelAgentSchedulerTask(webUiUrl, 't1', none);
      expect(recorder.requests.last.summary, 'POST /agent-scheduler/v1/delete/t1');
    });

    test('Agent Scheduler support is cached per server', () async {
      final recorder = RecordingClient(
        (_) => RecordingClient.json(
          '{ "paths": { "/agent-scheduler/v1/queue/txt2img": {}, "/agent-scheduler/v1/results/{id}": {} } }',
        ),
      );
      final client = SdClient(httpClient: recorder.client);
      expect(await client.trySupportsAgentScheduler(webUiUrl, none), isTrue);
      expect(await client.trySupportsAgentScheduler(webUiUrl, none), isTrue);
      expect(recorder.requests, hasLength(1));
    });

    test('credentials in the base URL become a basic authorization header', () async {
      final recorder = RecordingClient((_) => RecordingClient.json('[]'));
      await SdClient(httpClient: recorder.client).getSamplerNames('http://user:p%40ss@127.0.0.1:7860/', none);
      final request = recorder.requests.single;
      expect(request.uri.toString(), 'http://127.0.0.1:7860/sdapi/v1/samplers');
      expect(request.authorization, 'Basic ${base64.encode(utf8.encode('user:p@ss'))}');
    });

    test('non-success statuses surface the FastAPI detail', () async {
      final recorder = RecordingClient((_) => RecordingClient.json('{ "detail": "Not authenticated" }', 401));
      await expectLater(
        SdClient(httpClient: recorder.client).getCheckpointNames(webUiUrl, none),
        throwsA(
          isA<HttpStatusException>()
              .having((error) => error.statusCode, 'statusCode', 401)
              .having((error) => error.toString(), 'text', contains('Not authenticated')),
        ),
      );
    });

    test('checkServer explains a missing --api flag', () async {
      final recorder = RecordingClient((_) => RecordingClient.json('{ "detail": "Not Found" }', 404));
      final result = await SdClient(httpClient: recorder.client).checkServer(webUiUrl, ApiPlatform.webUi, none);
      expect(result.ok, isFalse);
      expect(result.message, contains('--api'));
    });

    test('a cancelled token stops a request', () async {
      final source = CancellationSource()..cancel();
      final recorder = RecordingClient((_) => RecordingClient.json('[]'));
      await expectLater(
        SdClient(httpClient: recorder.client).getSamplerNames(webUiUrl, source.token),
        throwsA(isA<OperationCanceledException>()),
      );
      expect(recorder.requests, isEmpty);
    });
  });

  group('Txt2ImgRequest', () {
    test('omits null fields and nests override settings', () {
      final json = Txt2ImgRequest(
        prompt: 'p',
        sdModelCheckpoint: 'model.safetensors',
        clipStopAtLastLayers: 2,
      ).toJson();
      expect(json.containsKey('negative_prompt'), isFalse);
      expect(json.containsKey('enable_hr'), isFalse);
      expect(json['override_settings'], {'sd_model_checkpoint': 'model.safetensors', 'CLIP_stop_at_last_layers': 2});
      expect(json['override_settings_restore_afterwards'], isTrue);
      expect(json['seed'], -1);
    });
  });

  group('ComfyWorkflow', () {
    test('chains LoRAs and CLIP skip into the txt2img graph', () {
      final request = createRequest()
        ..clipSkip = 2
        ..selectedLoras = const [LoraSelection(name: 'style.safetensors', weight: 0.8)]
        ..enableHiresFix = true
        ..hiresScale = 1.5
        ..hiresSteps = 10
        ..hiresDenoisingStrength = 0.4
        ..samplerName = 'Euler a'
        ..scheduler = 'Karras';
      final graph = ComfyWorkflow.buildTxt2ImgPrompt(
        request,
        checkpoint: 'model.safetensors',
        latentUpscaleMethod: 'bislerp',
        loraLoaderType: 'LoraLoader',
        supportsClipSetLastLayer: true,
      );

      Map<String, Object?> node(String id) => graph[id]! as Map<String, Object?>;
      Map<String, Object?> inputs(String id) => node(id)['inputs']! as Map<String, Object?>;
      final types = {for (final entry in graph.entries) entry.key: (entry.value! as Map)['class_type']};

      expect(types['4'], 'CheckpointLoaderSimple');
      expect(types['6'], 'LoraLoader');
      expect(types['7'], 'CLIPSetLastLayer');
      expect(inputs('7')['stop_at_clip_layer'], -2);
      expect(inputs('3')['sampler_name'], 'euler_ancestral');
      expect(inputs('3')['scheduler'], 'karras');
      expect(inputs('3')['model'], ['6', 0]);
      final hiresSampler = graph.entries.lastWhere((entry) => (entry.value! as Map)['class_type'] == 'KSampler').key;
      expect(inputs(hiresSampler)['steps'], 10);
      expect(inputs(hiresSampler)['denoise'], 0.4);
      final save = graph.entries.firstWhere((entry) => (entry.value! as Map)['class_type'] == 'SaveImage').key;
      expect((inputs(save)['images']! as List).first, isNot('3'));
    });

    test('resolves latent upscale methods from WebUI labels', () {
      expect(
        ComfyWorkflow.resolveLatentUpscaleMethod('Latent (nearest-exact)', const ['bislerp', 'nearest-exact']),
        'nearest-exact',
      );
      expect(ComfyWorkflow.resolveLatentUpscaleMethod('R-ESRGAN 4x+', const ['area', 'bicubic']), 'bicubic');
      expect(ComfyWorkflow.resolveLatentUpscaleMethod(null, const []), 'bislerp');
    });
  });
}
