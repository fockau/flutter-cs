import 'dart:convert';
import 'package:http/http.dart' as http;

class RemoteConfigData {
  final String apiPrefix; // 例如 /api/v1
  final List<String> domains; // 例如 ["https://a.com","https://b.com"]
  final String supportUrl;
  final String websiteUrl;

  const RemoteConfigData({
    required this.apiPrefix,
    required this.domains,
    required this.supportUrl,
    required this.websiteUrl,
  });

  Map<String, dynamic> toJson() => {
        'api_prefix': apiPrefix,
        'domains': domains,
        'support_url': supportUrl,
        'website_url': websiteUrl,
      };

  static RemoteConfigData fromJson(Map<String, dynamic> j) {
    final apiPrefix = (j['api_prefix'] ?? '/api/v1').toString().trim();
    final rawDomains = j['domains'];
    final domains = (rawDomains is List)
        ? rawDomains.map((e) => e.toString().trim()).where((e) => e.startsWith('http')).toSet().toList()
        : <String>[];

    return RemoteConfigData(
      apiPrefix: apiPrefix.isEmpty ? '/api/v1' : apiPrefix,
      domains: domains,
      supportUrl: (j['support_url'] ?? '').toString().trim(),
      websiteUrl: (j['website_url'] ?? '').toString().trim(),
    );
  }
}

class ConfigManager {
  static final ConfigManager I = ConfigManager._();
  ConfigManager._();

  // ======== 只改这里：你的远程 config.json 地址 ========
  static const String remoteConfigUrl = 'https://raw.githubusercontent.com/fockau/flutter-cs/refs/heads/main/config.json';
  // =====================================================

  Future<RemoteConfigData> fetchRemoteConfig({Duration timeout = const Duration(seconds: 6)}) async {
    final resp = await http.get(Uri.parse(remoteConfigUrl)).timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('remote config http ${resp.statusCode}');
    }

    final body = resp.body.trim();

    // 明文 JSON
    if (body.startsWith('{') && body.endsWith('}')) {
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) return RemoteConfigData.fromJson(j);
      throw Exception('remote config not object');
    }

    // base64(JSON)
    final decoded = utf8.decode(base64Decode(body));
    final j = jsonDecode(decoded);
    if (j is Map<String, dynamic>) return RemoteConfigData.fromJson(j);
    throw Exception('remote config base64 not object');
  }
}
