import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

class RemoteConfigModel {
  final List<String> domains; // 不带 /api/v1
  final String apiPrefix;     // /api/v1

  const RemoteConfigModel({required this.domains, required this.apiPrefix});

  static RemoteConfigModel fromJsonMap(Map<String, dynamic> m) {
    final prefix = (m['api_prefix'] ?? BootstrapConfig.apiPrefix).toString().trim();
    final rawDomains = m['domains'];

    List<String> domains = [];
    if (rawDomains is List) {
      domains = rawDomains.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    }

    domains = domains.map(_trimSlash).toList();
    domains = domains.toSet().toList();

    return RemoteConfigModel(domains: domains, apiPrefix: prefix.isEmpty ? BootstrapConfig.apiPrefix : prefix);
  }
}

String _trimSlash(String s) {
  s = s.trim();
  while (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
}

Uri _guestConfigUri(String domain, String apiPrefix) {
  domain = _trimSlash(domain);
  apiPrefix = apiPrefix.trim();
  if (!apiPrefix.startsWith('/')) apiPrefix = '/$apiPrefix';
  return Uri.parse('$domain$apiPrefix/guest/comm/config');
}

bool _looksLikeBase64(String s) {
  // 宽松判断：只要字符集接近 base64，且长度合理
  final t = s.trim();
  if (t.length < 16) return false;
  return RegExp(r'^[A-Za-z0-9+/=\r\n]+$').hasMatch(t);
}

class RaceResult {
  final String domain;
  final int latencyMs;
  const RaceResult(this.domain, this.latencyMs);
}

class ConfigManager {
  ConfigManager._();
  static final ConfigManager I = ConfigManager._();

  static const _kCachedRemoteRaw = 'rc_raw';
  static const _kSelectedDomain = 'selected_domain';
  static const _kSelectedApiPrefix = 'selected_api_prefix';

  bool _inited = false;

  String _apiPrefix = BootstrapConfig.apiPrefix;
  String _selectedDomain = ''; // 不带 /api/v1
  List<String> _domains = [];

  String get apiPrefix => _apiPrefix;
  String get apiBaseUrl => _selectedDomain; // 直接是域名（不含 /api/v1）
  String get siteBaseUrl => '$_selectedDomain$_apiPrefix'; // 给你“网站默认带 /api/v1”的展示/跳转用

  bool get ready => _selectedDomain.isNotEmpty;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;

    final sp = await SharedPreferences.getInstance();
    final cachedDomain = sp.getString(_kSelectedDomain) ?? '';
    final cachedPrefix = sp.getString(_kSelectedApiPrefix) ?? '';
    if (cachedDomain.isNotEmpty) _selectedDomain = cachedDomain;
    if (cachedPrefix.isNotEmpty) _apiPrefix = cachedPrefix;

    // 尝试加载远程配置（失败也不阻塞）
    await refreshRemoteConfigAndRace();
  }

  Future<void> refreshRemoteConfigAndRace() async {
    final sp = await SharedPreferences.getInstance();

    String raw = '';
    try {
      final resp = await http
          .get(Uri.parse(BootstrapConfig.remoteConfigUrl))
          .timeout(Duration(seconds: BootstrapConfig.raceTimeoutSeconds));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        raw = resp.body;
        await sp.setString(_kCachedRemoteRaw, raw);
      }
    } catch (_) {
      // ignore
    }

    if (raw.isEmpty) {
      raw = sp.getString(_kCachedRemoteRaw) ?? '';
    }

    // 解析远程配置
    RemoteConfigModel? rc;
    if (raw.isNotEmpty) {
      rc = _parseRemoteConfig(raw);
    }

    // 合并域名来源：远程 + fallback
    if (rc != null) {
      _apiPrefix = rc.apiPrefix;
      _domains = [...rc.domains, ...BootstrapConfig.fallbackDomains].map(_trimSlash).toList();
    } else {
      _apiPrefix = BootstrapConfig.apiPrefix;
      _domains = [...BootstrapConfig.fallbackDomains].map(_trimSlash).toList();
    }

    _domains = _domains.where((d) => d.startsWith('http://') || d.startsWith('https://')).toSet().toList();

    // 如果没有任何域名，保留之前已选域名（若有）
    if (_domains.isEmpty) {
      if (_selectedDomain.isNotEmpty) {
        await sp.setString(_kSelectedDomain, _selectedDomain);
        await sp.setString(_kSelectedApiPrefix, _apiPrefix);
      }
      return;
    }

    // 竞速：对每个域名测 /guest/comm/config
    final best = await racePickFastestDomain(_domains, _apiPrefix);
    if (best != null) {
      _selectedDomain = best.domain;
      await sp.setString(_kSelectedDomain, _selectedDomain);
      await sp.setString(_kSelectedApiPrefix, _apiPrefix);
    }
  }

  RemoteConfigModel? _parseRemoteConfig(String raw) {
    final t = raw.trim();

    // 先按 JSON 尝试
    Map<String, dynamic>? tryJson(String s) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
      return null;
    }

    final j1 = tryJson(t);
    if (j1 != null) return RemoteConfigModel.fromJsonMap(j1);

    // 再按 base64(JSON) 尝试
    if (_looksLikeBase64(t)) {
      try {
        final normalized = t.replaceAll('\n', '').replaceAll('\r', '');
        final bytes = base64Decode(normalized);
        final s = utf8.decode(bytes);
        final j2 = tryJson(s);
        if (j2 != null) return RemoteConfigModel.fromJsonMap(j2);
      } catch (_) {
        // ignore
      }
    }
    return null;
  }

  Future<RaceResult?> racePickFastestDomain(List<String> domains, String apiPrefix) async {
    if (domains.isEmpty) return null;

    final timeout = Duration(seconds: BootstrapConfig.raceTimeoutSeconds);

    Future<RaceResult?> probe(String domain) async {
      final uri = _guestConfigUri(domain, apiPrefix);
      final sw = Stopwatch()..start();
      try {
        final resp = await http.get(uri, headers: const {'Accept': 'application/json'}).timeout(timeout);
        sw.stop();
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          return RaceResult(domain, sw.elapsedMilliseconds);
        }
      } catch (_) {
        sw.stop();
      }
      return null;
    }

    // 并发探测
    final futures = domains.map(probe).toList();
    final results = await Future.wait(futures);

    final ok = results.whereType<RaceResult>().toList();
    if (ok.isEmpty) return null;

    ok.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    return ok.first;
  }
}
