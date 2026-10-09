import 'dart:convert';
import 'dart:io';

import 'package:selldatatoai/selldatatoai.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late DataAssetScoreClient client;
  var polls = 0;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      void send(int code, Object body) {
        req.response.statusCode = code;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode(body));
        req.response.close();
      }

      if (req.headers.value('x-api-key') != 'k') return send(401, {'error': 'invalid_api_key'});
      final p = req.uri.path;
      if (p == '/v1/score' && req.uri.queryParameters['domain'] == 'bad') return send(400, {'error': 'invalid_domain'});
      if (p == '/v1/score') return send(200, {'domain': 'example-labs.com', 'data_asset_score': 82, 'grade': 'A', 'history': {'pre_ai_years': 25}});
      if (p == '/v1/usage') return send(200, {'plan': 'pro', 'remaining': 3});
      if (p == '/v1/score/batch' && req.method == 'POST') {
        await utf8.decoder.bind(req).join();
        return send(202, {'id': 'b_1', 'status': 'processing'});
      }
      polls++;
      if (polls < 2) return send(200, {'id': 'b_1', 'status': 'processing'});
      send(200, {
        'id': 'b_1',
        'status': 'done',
        'results': [
          {'input': 'a.com', 'status': 'done', 'result': {'data_asset_score': 70}}
        ]
      });
    });
    client = DataAssetScoreClient('k',
        baseUrl: 'http://127.0.0.1:${server.port}/v1', pollInterval: const Duration(milliseconds: 10));
  });

  tearDownAll(() => server.close(force: true));

  test('score and usage', () async {
    final s = await client.score('example-labs.com');
    expect(s.grade, 'A');
    expect(s.preAiYears, 25);
    expect((await client.usage())['remaining'], 3);
  });

  test('api errors carry status and code', () async {
    await expectLater(client.score('bad'),
        throwsA(isA<SellDataToAIException>().having((e) => e.code, 'code', 'invalid_domain')));
  });

  test('scoreMany waits for the batch', () async {
    final items = await client.scoreMany(['a.com']);
    expect(items.first['result']['data_asset_score'], 70);
  });
}
