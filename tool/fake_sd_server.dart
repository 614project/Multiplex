// Serves the fake WebUI / Agent Scheduler / ComfyUI API from test/support over real HTTP, for trying
// the app without a GPU:
//
//   dart run tool/fake_sd_server.dart [port] [generation-ms] [image-size]
//
// Point a project at http://127.0.0.1:<port> (WebUI or ComfyUI both work on the same port).
import 'dart:io';

import 'package:http/http.dart' as http;

import '../test/support/fake_sd_server.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 7860;
  final generationMs = args.length > 1 ? int.parse(args[1]) : 2500;
  final imageSize = args.length > 2 ? int.parse(args[2]) : 512;
  final fake = FakeSdServer(
    generationTime: Duration(milliseconds: generationMs),
    imageSize: imageSize,
  );
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('Fake Stable Diffusion server listening on http://127.0.0.1:$port');

  await for (final request in server) {
    try {
      final body = await request.fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk));
      final forwarded = http.Request(request.method, request.requestedUri)..bodyBytes = body;
      request.headers.forEach((name, values) => forwarded.headers[name] = values.join(','));
      final response = await fake.handle(forwarded);
      stdout.writeln('${request.method} ${request.uri} -> ${response.statusCode}');
      request.response.statusCode = response.statusCode;
      response.headers.forEach(request.response.headers.set);
      request.response.add(response.bodyBytes);
      await request.response.close();
    } catch (error) {
      stderr.writeln('Request failed: $error');
      request.response.statusCode = 500;
      await request.response.close();
    }
  }
}
