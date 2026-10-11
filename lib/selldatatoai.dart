/// Dart client for the AI Data Value Score API at https://www.selldatatoai.com/api/ .
///
/// Scores company domains from 0 to 100 for the data AI buyers want.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String version = '1.0.1';
const String defaultBaseUrl = 'https://www.selldatatoai.com/api/v1';
const int batchMax = 100;

/// Thrown for a non-2xx answer (status > 0) or a timeout/transport problem (status 0).
class SellDataToAIException implements Exception {
  final int status;
  final String? code;
  final String message;
  final Object? body;
  SellDataToAIException(this.status, this.code, this.message, [this.body]);
  @override
  String toString() => 'SellDataToAIException($status, $code): $message';
}

/// One scored company. [raw] keeps every field of the answer.
class Score {
  final Map<String, dynamic> raw;
  Score(this.raw);
  String get domain => raw['domain'] as String;
  int get dataAssetScore => (raw['data_asset_score'] as num).toInt();
  String get grade => raw['grade'] as String;
  String get status => raw['status'] as String;
  bool get verifiedActive => raw['verified_active'] == true;
  String? get iabCategory => raw['iab_category'] as String?;
  String? get country => raw['country'] as String?;
  Map<String, dynamic> get history => (raw['history'] as Map?)?.cast<String, dynamic>() ?? const {};
  int? get yearsOnline => (history['years_online'] as num?)?.toInt();
  int? get preAiYears => (history['pre_ai_years'] as num?)?.toInt();
  bool get preAiArchiveLikely => raw['pre_ai_archive_likely'] == true;
  List<Map<String, dynamic>> get dataSystems => _list('data_systems');
  List<Map<String, dynamic>> get likelyDataAssets => _list('likely_data_assets');
  List<String> get strengths => ((raw['strengths'] as List?) ?? const []).cast<String>();
  String? get dataCoverage => raw['data_coverage'] as String?;
  bool get cached => raw['cached'] == true;
  List<Map<String, dynamic>> _list(String k) =>
      ((raw[k] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();
}

class DataAssetScoreClient {
  final String apiKey;
  final String baseUrl;
  final Duration timeout;
  Duration pollInterval;
  Duration maxWait;
  final HttpClient _http;

  DataAssetScoreClient(this.apiKey,
      {String baseUrl = defaultBaseUrl,
      this.timeout = const Duration(seconds: 60),
      this.pollInterval = const Duration(seconds: 5),
      this.maxWait = const Duration(minutes: 5),
      HttpClient? httpClient})
      : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _http = httpClient ?? HttpClient() {
    if (apiKey.isEmpty) {
      throw ArgumentError('An API key is required. Plans: https://www.selldatatoai.com/pricing/');
    }
    _http.userAgent = 'selldatatoai-dart/$version (+https://www.selldatatoai.com)';
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, String>? query, Object? body}) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    try {
      final req = await _http.openUrl(method, uri).timeout(timeout);
      req.headers.set('X-API-Key', apiKey);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      Object? data;
      try {
        data = jsonDecode(text);
      } on FormatException {
        data = null;
      }
      if (res.statusCode >= 200 && res.statusCode < 300 && data is Map) {
        return data.cast<String, dynamic>();
      }
      final m = data is Map ? data : const {};
      throw SellDataToAIException(
          res.statusCode, m['error'] as String?, (m['message'] as String?) ?? 'HTTP ${res.statusCode}', data ?? text);
    } on TimeoutException {
      throw SellDataToAIException(0, 'timeout', 'No answer within ${timeout.inSeconds} s');
    } on SocketException catch (e) {
      throw SellDataToAIException(0, 'transport', e.message);
    }
  }

  /// Score one company domain. Full URLs are accepted.
  Future<Score> score(String domain) async {
    if (domain.trim().isEmpty) throw ArgumentError('domain is empty');
    return Score(await _request('GET', '/score', query: {'domain': domain.trim()}));
  }

  /// Submit 1 to 100 domains. One lookup per valid, unique domain.
  Future<Map<String, dynamic>> submitBatch(List<String> domains) {
    if (domains.isEmpty || domains.length > batchMax) {
      throw ArgumentError('A batch takes 1 to $batchMax domains');
    }
    return _request('POST', '/score/batch', body: {'domains': domains});
  }

  /// Poll a batch. Polling is free.
  Future<Map<String, dynamic>> getBatch(String id) => _request('GET', '/score/batch', query: {'id': id});

  /// Poll until the batch is done or [maxWait] passes.
  Future<Map<String, dynamic>> waitForBatch(String id) async {
    final stop = DateTime.now().add(maxWait);
    while (true) {
      final b = await getBatch(id);
      if (b['status'] == 'done') return b;
      if (DateTime.now().isAfter(stop)) {
        throw SellDataToAIException(0, 'batch_timeout', 'Batch $id still processing', b);
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// Score any number of domains in batches of 100; items come back in input order.
  Future<List<Map<String, dynamic>>> scoreMany(List<String> domains) async {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < domains.length; i += batchMax) {
      final end = i + batchMax < domains.length ? i + batchMax : domains.length;
      var b = await submitBatch(domains.sublist(i, end));
      if (b['status'] != 'done') b = await waitForBatch(b['id'] as String);
      out.addAll(((b['results'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()));
    }
    return out;
  }

  /// Plan, lookups used this month and lookups remaining.
  Future<Map<String, dynamic>> usage() => _request('GET', '/usage');

  /// Close the underlying HTTP client.
  void close() => _http.close();
}
