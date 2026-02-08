import 'dart:convert';
import 'package:http/http.dart' as http;

import 'domain_racer.dart';
import 'session_service.dart';

class GuestConfigParsed {
  final int isEmailVerify;
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
      suffix = raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toSet().toList()..sort();
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

  // 订阅请求保守超时（你要更快可调小）
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

  Future<void> initResolveDomain() async {
    final r = await DomainRacer.I.resolve();
    _baseUrl = r.baseUrl;
    _apiPrefix = r.config.apiPrefix;
    supportUrl = r.config.supportUrl;
    websiteUrl = r.config.websiteUrl;
    _ready = true;
  }

  Future<GuestConfigParsed> fetchGuestConfig() async {
    if (!_ready) await initResolveDomain();
    final resp = await http.get(_api('/guest/comm/config'), headers: _headers()).timeout(normalTimeout);

    final j = jsonDecode(resp.body);
    if (resp.statusCode != 200 || j is! Map<String, dynamic>) {
      throw Exception('guest config http ${resp.statusCode}');
    }
    return GuestConfigParsed.fromResponse(j);
  }

  Future<Map<String, dynamic>> login({required String email, required String password}) async {
    if (!_ready) await initResolveDomain();
    final resp = await http
        .post(
          _api('/passport/auth/login'),
          headers: _headers(json: true),
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(normalTimeout);

    final j = jsonDecode(resp.body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception((j is Map && j['message'] != null) ? j['message'] : 'HTTP ${resp.statusCode}');
    }
    if (j is! Map<String, dynamic>) throw Exception('login response not object');
    return j;
  }

  Future<Map<String, dynamic>> getSubscribe() async {
    if (!_ready) await initResolveDomain();
    final resp = await http.get(_api('/user/getSubscribe'), headers: _headers(auth: true)).timeout(subscribeTimeout);

    final j = jsonDecode(resp.body);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final msg = (j is Map && j['message'] != null) ? j['message'].toString() : 'HTTP ${resp.statusCode}';
      throw Exception(msg);
    }
    if (j is! Map<String, dynamic>) throw Exception('subscribe response not object');
    return j;
  }
}
