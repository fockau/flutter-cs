import 'dart:convert';
import 'package:http/http.dart' as http;

import 'domain_racer.dart';
import 'session_service.dart';

class GuestConfigParsed {
  final int isEmailVerify; // 0/1
  final List<String> emailWhitelistSuffix;
  final String? appDescription;

  const GuestConfigParsed({
    required this.isEmailVerify,
    required this.emailWhitelistSuffix,
    this.appDescription,
  });

  static GuestConfigParsed fromResponse(Map<String, dynamic> j) {
    final data = j['data'];
    if (data is! Map) {
      return const GuestConfigParsed(isEmailVerify: 0, emailWhitelistSuffix: []);
    }

    int toInt(dynamic v) {
      if (v is bool) return v ? 1 : 0;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    final isEmailVerify = toInt(data['is_email_verify']);
    final raw = data['email_whitelist_suffix'];

    List<String> suffix = [];
    if (raw is List) {
      suffix = raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
    }

    return GuestConfigParsed(
      isEmailVerify: isEmailVerify,
      emailWhitelistSuffix: suffix,
      appDescription: data['app_description']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'is_email_verify': isEmailVerify,
        'email_whitelist_suffix': emailWhitelistSuffix,
        'app_description': appDescription,
      };
}

class XBoardApi {
  static final XBoardApi I = XBoardApi._();
  XBoardApi._();

  static const subscribeTimeout = Duration(seconds: 8);
  static const normalTimeout = Duration(seconds: 10);

  late String _baseUrl;
  late String _apiPrefix;
  late String supportUrl;
  late String websiteUrl;

  bool _ready = false;
  bool get ready => _ready;

  Uri _api(String pathUnderApiV1) {
    var p = pathUnderApiV1.trim();
    if (!p.startsWith('/')) p = '/$p';
    return Uri.parse('$_baseUrl$_apiPrefix$p');
  }

  Map<String, String> _headers({bool json = false, bool auth = false}) {
    final h = <String, String>{'Accept': 'application/json'};
    if (json) h['Content-Type'] = 'application/json';
    if (auth) {
      final a = SessionService.I.authData.trim();
      if (a.isNotEmpty) h['Authorization'] = a;

      final c = SessionService.I.cookie.trim();
      if (c.isNotEmpty) h['Cookie'] = c;
    }
    return h;
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    required Map<String, dynamic> body,
    bool auth = false,
  }) async {
    if (!_ready) await initResolveDomain();
    final resp = await http
        .post(
          _api(path),
          headers: _headers(json: true, auth: auth),
          body: jsonEncode(body),
        )
        .timeout(normalTimeout);

    final dynamic j = jsonDecode(resp.body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final msg = (j is Map && j['message'] != null) ? j['message'].toString() : 'HTTP ${resp.statusCode}';
      throw Exception(msg);
    }
    if (j is! Map<String, dynamic>) throw Exception('response not object');
    return j;
  }

  Future<void> initResolveDomain() async {
    final r = await DomainRacer.I.resolve();
    _baseUrl = r.baseUrl;
    _apiPrefix = r.config.apiPrefix;
    supportUrl = r.config.supportUrl;
    websiteUrl = r.config.websiteUrl;
    _ready = true;
  }

  /// 公共配置（不需要认证）
  Future<GuestConfigParsed> fetchGuestConfig() async {
    if (!_ready) await initResolveDomain();
    final resp = await http.get(_api('/guest/comm/config'), headers: _headers()).timeout(normalTimeout);

    final dynamic j = jsonDecode(resp.body);
    if (resp.statusCode != 200 || j is! Map<String, dynamic>) {
      throw Exception('guest config http ${resp.statusCode}');
    }
    return GuestConfigParsed.fromResponse(j);
  }

  /// 登录
  Future<Map<String, dynamic>> login({required String email, required String password}) async {
    return _postJson(
      '/passport/auth/login',
      body: {'email': email, 'password': password},
      auth: false,
    );
  }

  /// 注册（inviteCode 可选）
  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    String? inviteCode,
    String? emailCode,
  }) async {
    final body = <String, dynamic>{
      'email': email,
      'password': password,
    };
    if (inviteCode != null && inviteCode.trim().isNotEmpty) {
      body['invite_code'] = inviteCode.trim();
    }
    if (emailCode != null && emailCode.trim().isNotEmpty) {
      body['email_code'] = emailCode.trim();
    }
    return _postJson('/passport/auth/register', body: body, auth: false);
  }

  /// 发送邮箱验证码：scene 自动传入（register / reset_password）
  Future<Map<String, dynamic>> sendEmailCode({
    required String email,
    required String scene,
  }) async {
    return _postJson(
      '/passport/auth/sendEmailCode',
      body: {'email': email, 'scene': scene},
      auth: false,
    );
  }

  /// 重置密码
  Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String password,
    required String emailCode,
  }) async {
    return _postJson(
      '/passport/auth/resetPassword',
      body: {'email': email, 'password': password, 'email_code': emailCode},
      auth: false,
    );
  }

  /// 登出（可选调用，前端仍需清 token）
  Future<void> logout() async {
    try {
      await _postJson('/passport/auth/logout', body: {}, auth: true);
    } catch (_) {
      // 后端不通/返回错误也不影响前端清 session
    }
  }

  /// 获取订阅（需要认证）
  Future<Map<String, dynamic>> getSubscribe() async {
    if (!_ready) await initResolveDomain();
    final resp = await http.get(_api('/user/getSubscribe'), headers: _headers(auth: true)).timeout(subscribeTimeout);

    final dynamic j = jsonDecode(resp.body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final msg = (j is Map && j['message'] != null) ? j['message'].toString() : 'HTTP ${resp.statusCode}';
      throw Exception(msg);
    }
    if (j is! Map<String, dynamic>) throw Exception('subscribe response not object');
    return j;
  }
}
