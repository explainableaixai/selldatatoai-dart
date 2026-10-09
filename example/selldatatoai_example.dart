import 'dart:io';

import 'package:selldatatoai/selldatatoai.dart';

Future<void> main(List<String> args) async {
  final client = DataAssetScoreClient(Platform.environment['SDA_API_KEY'] ?? '');
  final s = await client.score(args.isEmpty ? 'example.com' : args.first);
  print('${s.domain}: ${s.dataAssetScore} (${s.grade}), ${s.yearsOnline} years online');
  client.close();
}
