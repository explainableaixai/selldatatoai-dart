# selldatatoai

Dart package for scoring companies with the [Data Asset Score REST API](https://www.selldatatoai.com/api/). One call turns a company website into a 0 to 100 score for the data AI buyers want, with a grade, a status, the systems of record the company runs and its web history.

```yaml
dependencies:
  selldatatoai: ^1.0.0
```

```dart
import 'package:selldatatoai/selldatatoai.dart';
```

Built on `dart:io` with no third-party dependencies. Runs on the Dart VM: servers, command-line tools and desktop. Dart 3.0 or newer.

[SellDataToAI](https://www.selldatatoai.com/) runs the API on top of an index of 102 million domains, 99.99% of the active internet, with history for each domain.

## A note before you start: keep the key on a server

The API key is tied to a paid plan. Anything you ship inside a mobile or web app can be extracted, so never put the key in a Flutter build.

The safe pattern:

1. Your Flutter app calls your own backend.
2. Your backend, written in Dart with this package or in any other language, calls the API with the key.
3. The backend returns only the fields the app needs.

That is why the package targets the VM and not the browser.

## Usage

```dart
import 'dart:io';
import 'package:selldatatoai/selldatatoai.dart';

Future<void> main() async {
  final client = DataAssetScoreClient(Platform.environment['SDA_API_KEY']!);
  try {
    final s = await client.score('example.com');
    print('${s.domain}: ${s.dataAssetScore} (${s.grade}), ${s.status}');
    print('online ${s.yearsOnline} years, ${s.preAiYears} of them before 2023');
    for (final sys in s.dataSystems) {
      print('runs ${sys['system']} -> ${sys['data_type']}');
    }
  } on SellDataToAIException catch (e) {
    stderr.writeln('failed: ${e.status} ${e.code} ${e.message}');
  } finally {
    client.close();
  }
}
```

The `Score` object gives typed getters for the common fields and keeps the whole answer in `raw`, so new fields are readable the day they appear.

### Score getters

| Getter | Type | From field |
|---|---|---|
| `domain` | `String` | `domain` |
| `dataAssetScore` | `int` | `data_asset_score` |
| `grade` | `String` | `grade` |
| `status` | `String` | `status` |
| `verifiedActive` | `bool` | `verified_active` |
| `iabCategory` | `String?` | `iab_category` |
| `country` | `String?` | `country` |
| `history` | `Map` | `history` |
| `yearsOnline` | `int?` | `history.years_online` |
| `preAiYears` | `int?` | `history.pre_ai_years` |
| `preAiArchiveLikely` | `bool` | `pre_ai_archive_likely` |
| `dataSystems` | `List<Map>` | `data_systems` |
| `likelyDataAssets` | `List<Map>` | `likely_data_assets` |
| `strengths` | `List<String>` | `strengths` |
| `dataCoverage` | `String?` | `data_coverage` |
| `cached` | `bool` | `cached` |

### Client members

```dart
DataAssetScoreClient(String apiKey, {
  String baseUrl = 'https://www.selldatatoai.com/api/v1',
  Duration timeout = const Duration(seconds: 60),
  Duration pollInterval = const Duration(seconds: 5),
  Duration maxWait = const Duration(minutes: 5),
  HttpClient? httpClient,
});

Future<Score> score(String domain);                         // 1 lookup
Future<Map<String, dynamic>> submitBatch(List<String> d);   // 1 per valid, unique domain
Future<Map<String, dynamic>> getBatch(String id);           // free
Future<Map<String, dynamic>> waitForBatch(String id);       // free
Future<List<Map<String, dynamic>>> scoreMany(List<String>); // batches of 100
Future<Map<String, dynamic>> usage();                       // free
void close();
```

Pass your own `HttpClient` to set a proxy, custom certificates or connection limits.

## Exceptions

`SellDataToAIException` has `status`, `code`, `message` and `body`. `status` is the HTTP code, or 0 for a timeout (`code: 'timeout'`), a socket failure (`code: 'transport'`) or a batch that ran past `maxWait` (`code: 'batch_timeout'`).

| status | code | When |
|---|---|---|
| 400 | `invalid_domain` | the input is not a domain |
| 400 | `no_domains`, `too_many_domains` | batch size outside 1 to 100 |
| 401 | `missing_api_key`, `invalid_api_key` | no key, or plan not active |
| 404 | `batch_not_found` | unknown id, or older than 7 days |
| 410 | `not_available` | lists are not part of the API |
| 429 | `monthly_limit_reached` | lookups used for this month |
| 429 | `batch_busy` | three batches open already |

`ArgumentError` is thrown locally for an empty key, an empty domain or a batch list of the wrong size. No request is sent and no lookup is used.

## Examples

### A backend route with shelf

```dart
import 'dart:convert';
import 'dart:io';
import 'package:selldatatoai/selldatatoai.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

final sda = DataAssetScoreClient(Platform.environment['SDA_API_KEY']!);

Future<Response> handler(Request req) async {
  final site = req.url.queryParameters['website'];
  if (site == null) return Response.badRequest(body: 'website is required');
  try {
    final s = await sda.score(site);
    return Response.ok(jsonEncode({
      'score': s.dataAssetScore,
      'grade': s.grade,
      'active': s.verifiedActive,
      'holds': s.likelyDataAssets.map((a) => a['label']).toList(),
    }), headers: {'content-type': 'application/json'});
  } on SellDataToAIException catch (e) {
    return Response(e.status == 400 ? 422 : 502, body: e.code ?? 'error');
  }
}

Future<void> main() async => io.serve(handler, InternetAddress.anyIPv4, 8080);
```

Your Flutter app calls this route, and the key never leaves the server.

### A command-line ranker

```dart
// dart run bin/rank.dart domains.txt
import 'dart:io';
import 'package:selldatatoai/selldatatoai.dart';

Future<void> main(List<String> args) async {
  final client = DataAssetScoreClient(Platform.environment['SDA_API_KEY']!);
  final domains = (await File(args.first).readAsLines())
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();

  final left = (await client.usage())['remaining'] as int;
  if (domains.length > left) {
    stderr.writeln('${domains.length} domains, $left lookups left');
    exit(2);
  }

  final items = await client.scoreMany(domains);
  final scored = items
      .where((it) => it['status'] == 'done')
      .map((it) => Score((it['result'] as Map).cast<String, dynamic>()))
      .where((s) => s.verifiedActive)
      .toList()
    ..sort((a, b) => b.dataAssetScore.compareTo(a.dataAssetScore));

  for (final s in scored.take(25)) {
    print('${s.domain.padRight(30)} ${s.dataAssetScore.toString().padLeft(3)} ${s.grade}');
  }
  client.close();
}
```

### Polling a batch yourself

```dart
final sent = await client.submitBatch(['example-one.com', 'example-two.com']);
print('charged ${sent['lookups_charged']} lookups');

var batch = sent;
while (batch['status'] != 'done') {
  await Future<void>.delayed(const Duration(seconds: 5));
  batch = await client.getBatch(sent['id'] as String);
}
for (final item in batch['results'] as List) {
  print('${item['input']}: ${item['status']}');
}
```

## Caching on your side

The API reuses each result for 30 days, and every call still counts as a lookup. If your backend asks about the same company again and again, for example on every page view of a partner profile, keep your own copy.

```dart
final _cache = <String, (DateTime, Score)>{};

Future<Score> cachedScore(DataAssetScoreClient c, String domain) async {
  final key = domain.toLowerCase();
  final hit = _cache[key];
  if (hit != null && DateTime.now().difference(hit.$1) < const Duration(days: 30)) {
    return hit.$2;
  }
  final s = await c.score(domain);
  _cache[key] = (DateTime.now(), s);
  return s;
}
```

In production, store `s.raw` as JSON in your database next to the company row, with `checked_at` from the answer. That keeps the cache across restarts and lets you report when each score was taken.

## Timeouts and retries

- The default timeout is 60 seconds per request. A fresh score can take a while for a site that answers slowly; cached ones return at once.
- Retry only on `status == 0` (timeout or socket error) or on 5xx answers. A 400 will not change on retry.
- Never retry a `monthly_limit_reached`. Check `usage()` and wait for the first day of the month, UTC.
- For a list of more than a few dozen domains, use `scoreMany`. One batch replaces up to 100 requests.

## Batch rules

- 1 to 100 domains per submit.
- One lookup per valid, unique domain, charged at submit. Invalid rows and duplicates are free.
- Domains scored in the last 30 days answer at once; the others usually within a minute.
- Polling is free. Results keep input order and are kept for 7 days.
- Up to three open batches per key. `scoreMany` sends one at a time.

## Who uses the score, and for what

Brokers and data companies place company records with AI labs. Before a deal, they need to know which companies hold enough of the right records, in systems that can be exported. The score is that first filter.

Two guides on the website help with the steps after it. The walk-through of the [AI data licensing agreement](https://www.selldatatoai.com/ai-data-licensing-agreement/) covers the contract clause by clause. The comparison of [AI data collection companies](https://www.selldatatoai.com/ai-data-collection-companies/) explains how buying new data on request differs from licensing records that already exist.

Some sectors hold more than others. Drug makers keep decades of trial, quality and regulatory records, and the [list of pharmaceutical companies](https://www.selldatatoai.com/list-of-pharmaceutical-companies/) page shows which US firms make practical partners.

Buyers also ask for one record type across sectors. Support conversations are a common request, so there is a ready file of [companies with customer support tickets](https://www.selldatatoai.com/lists/data-type/customer-support-tickets/). Lists are one-time files, separate from the API.

## Plans

No free plan, no trial, no sandbox key. The website demo allows 5 checks a day.

- Basic: $99 a month, 5,000 lookups.
- Pro: $299 a month, 25,000 lookups, batch scoring.
- Scale: $799 a month, 100,000 lookups, batch scoring.

The [monthly lookup plans](https://www.selldatatoai.com/pricing/) reset on the first day of each month, UTC. A cached answer counts as a lookup, like a fresh one.

## FAQ

### What is the selldatatoai Dart package?

The selldatatoai Dart package is a client for the Data Asset Score API at selldatatoai.com. It scores company websites from 0 to 100 for the data AI buyers want and returns the grade, status, data systems, likely data assets and web history.

### Does it work in Flutter?

It runs on the Dart VM, so it works in Flutter desktop builds and Dart servers. Do not ship your key in a mobile or web app; call the API from a backend.

### Why are batch results maps instead of classes?

Batch answers carry a status per row and an optional result. Wrap a finished row in `Score(...)` to get the typed getters, as the ranker example shows.

### How long are results reused?

30 days. After that the domain is scored again, and the score can move.

### Are the weights published?

No. The factor groups are described on the website; the weights and rules stay private.

## Links

- Package page: [pub.dev](https://pub.dev/packages/selldatatoai)
- Asynchronous programming in Dart: [dart.dev](https://dart.dev/libraries/async/async-await)
- Website: https://www.selldatatoai.com/
- Source: https://github.com/explainableaixai/selldatatoai-dart

## License

MIT. Copyright (c) 2026 Alpha Quantum. info@alpha-quantum.com
