import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class AppStorage {
  static final AppStorage I = AppStorage._();
  AppStorage._();

  SharedPreferences? _sp;

  Future<void> init() async {
    _sp ??= await SharedPreferences.getInstance();
  }

  // --- keys ---
  static const kEmail = 'email';
  static const kPassword = 'password';
  static const kRememberPassword = 'remember_password';
  static const kAuthData = 'auth_data';
  static const kCookie = 'cookie';

  static const kSubscribeCache = 'subscribe_cache';
  static const kGuestConfigCache = 'guest_config_cache';

  static const kRemoteConfigCache = 'remote_config_cache';
  static const kRemoteConfigCachedAt = 'remote_config_cached_at';

  static const kResolvedDomainBase = 'resolved_domain_base';
  static const kResolvedDomainLatency = 'resolved_domain_latency';
  static const kResolvedDomainCachedAt = 'resolved_domain_cached_at';

  // --- primitives ---
  String getString(String k) => _sp?.getString(k) ?? '';
  int getInt(String k) => _sp?.getInt(k) ?? 0;
  bool getBool(String k, {bool def = false}) => _sp?.getBool(k) ?? def;

  Future<void> setString(String k, String v) async => _sp?.setString(k, v);
  Future<void> setInt(String k, int v) async => _sp?.setInt(k, v);
  Future<void> setBool(String k, bool v) async => _sp?.setBool(k, v);

  Future<void> remove(String k) async => _sp?.remove(k);

  // --- json ---
  Map<String, dynamic>? getJson(String k) {
    final s = getString(k);
    if (s.isEmpty) return null;
    try {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return Map<String, dynamic>.from(j);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setJson(String k, Map<String, dynamic> v) async {
    await setString(k, jsonEncode(v));
  }
}
