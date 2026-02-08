import 'dart:convert';
import 'package:http/http.dart' as http;

import 'app_storage.dart';

class RemoteConfig {
  final String apiPrefix; // 例如 /api/v1
  final List<String> domains; // https://a.com
  final String supportUrl; // 客服
  final String websiteUrl; // 官网

  const RemoteConfig({
    required this.apiPrefix,
    required this.domains,
    required this.supportUrl,
    required this.websiteUrl,
  });

  static RemoteConfig fromJson(Map<String, dynamic> j) {
    final apiPrefix = (j['apiPrefix'] ?? '/api/v1').toString();
    final domainsRaw = j['domains'];
    final domains = (domainsRaw is List ? domainsRaw : <dynamic>[])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();

    final supportUrl = (j['supportUrl'] ?? '').toString();
    final websiteUrl = (j['websiteUrl'] ?? '').toString();

    if (domains.isEmpty) {
      throw Exception('remote config: domains 为空');
    }
    return RemoteConfig(apiPrefix: apiPrefix, domains: domains, supportUrl: supportUrl, websiteUrl: websiteUrl);
  }

  Map<String, dynamic> toJson() => {
        'apiPrefix': apiPrefix,
        'domains': domains,
        'supportUrl': supportUrl,
        'websiteUrl': websiteUrl,
      };
}

class ConfigManager {
  static final ConfigManager I = ConfigManager._();
  ConfigManager._();

  // TODO：改成你自己的地址
  static const String remoteConfigUrl = 'https://raw.githubusercontent.com/fockau/flutter-cs/refs/heads/main/config.json';

  // 远程是否为 base64（如果你服务端返回的是 base64 字符串就设 true）
  static const bool remoteIsBase64 = false;

  static const Duration cacheTtl = Duration(hours: 6);

  Future<RemoteConfig> loadRemoteConfig({bool forceRefresh = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cachedAt = AppStorage.I.getInt(AppStorage.kRemoteConfigCachedAt);

    if (!forceRefresh && cachedAt > 0 && (now - cachedAt) < cacheTtl.inMilliseconds) {
      final cached = AppStorage.I.getJson(AppStorage.kRemoteConfigCache);
      if (cached != null) return RemoteConfig.fromJson(cached);
    }

    final resp = await http.get(Uri.parse(remoteConfigUrl)).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) throw Exception('remote config http ${resp.statusCode}');

    Map<String, dynamic> j;
    if (remoteIsBase64) {
      final decoded = utf8.decode(base64Decode(resp.body.trim()));
      j = jsonDecode(decoded) as Map<String, dynamic>;
    } else {
      j = jsonDecode(resp.body) as Map<String, dynamic>;
    }

    final rc = RemoteConfig.fromJson(j);
    await AppStorage.I.setJson(AppStorage.kRemoteConfigCache, rc.toJson());
    await AppStorage.I.setInt(AppStorage.kRemoteConfigCachedAt, now);
    return rc;
  }
}
