import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config_manager.dart';
import 'auth_dialog.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'XBoard Client',
      theme: ThemeData(useMaterial3: true),
      home: const Home(),
    );
  }
}

Uri _apiV1(String pathUnderApiV1) {
  final base = ConfigManager.I.apiBaseUrl;
  final prefix = ConfigManager.I.apiPrefix;
  var p = pathUnderApiV1;
  if (!p.startsWith('/')) p = '/$p';
  return Uri.parse('$base$prefix$p');
}

String _prettyJsonIfPossible(String body) {
  try {
    final j = jsonDecode(body);
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(j);
  } catch (_) {
    return body;
  }
}

String _extractSubscribeUrl(dynamic j) {
  if (j is Map) {
    final data = j['data'];
    if (data is Map && data['subscribe_url'] != null) return '${data['subscribe_url']}';
  }
  return '';
}

String _extractAuthData(Map<String, dynamic> j) {
  final data = j['data'];
  if (data is Map && data['auth_data'] != null) return '${data['auth_data']}';
  if (data is Map && data['token'] != null) return 'Bearer ${data['token']}';
  return '';
}

String _extractSessionCookie(String? setCookie) {
  if (setCookie == null || setCookie.isEmpty) return '';
  final m = RegExp(r'(server_name_session=[^;]+)').firstMatch(setCookie);
  return m?.group(1) ?? '';
}

class Store {
  static const _kEmail = 'email';
  static const _kPassword = 'password';
  static const _kAuthData = 'auth_data';
  static const _kCookie = 'cookie';
  static const _kSubscribeUrl = 'subscribe_url';

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  static Future<void> saveAll({
    required String email,
    required String password,
    required String authData,
    required String cookie,
    required String subscribeUrl,
  }) async {
    final sp = await _sp();
    await sp.setString(_kEmail, email);
    await sp.setString(_kPassword, password);
    await sp.setString(_kAuthData, authData);
    await sp.setString(_kCookie, cookie);
    await sp.setString(_kSubscribeUrl, subscribeUrl);
  }

  static Future<String> email() async => (await _sp()).getString(_kEmail) ?? '';
  static Future<String> password() async => (await _sp()).getString(_kPassword) ?? '';
  static Future<String> authData() async => (await _sp()).getString(_kAuthData) ?? '';
  static Future<String> cookie() async => (await _sp()).getString(_kCookie) ?? '';
  static Future<String> subscribeUrl() async => (await _sp()).getString(_kSubscribeUrl) ?? '';

  static Future<void> clear() async {
    final sp = await _sp();
    await sp.remove(_kEmail);
    await sp.remove(_kPassword);
    await sp.remove(_kAuthData);
    await sp.remove(_kCookie);
    await sp.remove(_kSubscribeUrl);
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String email = '';
  String password = '';
  String authData = '';
  String cookie = '';
  String subscribeUrl = '';

  bool loading = false;
  int? respStatus;
  String? respText;
  int lastFetchedAtMs = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  Map<String, String> _headers() {
    final h = <String, String>{'Accept': 'application/json'};
    if (authData.isNotEmpty) h['Authorization'] = authData;
    if (cookie.isNotEmpty) h['Cookie'] = cookie;
    return h;
  }

  Future<Map<String, dynamic>> _parseJson(http.Response resp) async {
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) return decoded;
      throw Exception('Unexpected JSON type');
    } catch (_) {
      throw Exception('后端返回不是 JSON：HTTP ${resp.statusCode}\n${resp.body}');
    }
  }

  String _formatApiError(Map<String, dynamic> j, int statusCode) {
    final msg = j['message']?.toString() ?? 'HTTP $statusCode';
    final errs = j['errors'];
    if (errs == null) return msg;
    return '$msg\n$errs';
  }

  Future<void> _boot() async {
    await ConfigManager.I.init(); // ✅ 初始化远程配置 + 域名竞速

    email = await Store.email();
    password = await Store.password();
    authData = await Store.authData();
    cookie = await Store.cookie();
    subscribeUrl = await Store.subscribeUrl();
    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 先尝试自动登录
      if (email.isNotEmpty && password.isNotEmpty) {
        await _autoLoginAndFetch();
      }
      // 未登录：强制弹窗
      if (authData.isEmpty) {
        await _openAuthDialog(forceLogin: true);
      }
    });
  }

  Future<void> _autoLoginAndFetch() async {
    try {
      await _loginWithSavedCreds();
      await fetchSubscribe(showToast: false);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _loginWithSavedCreds() async {
    // 每次自动登录前也可以刷新一次竞速（可选）
    await ConfigManager.I.refreshRemoteConfigAndRace();

    final resp = await http
        .post(
          _apiV1('/passport/auth/login'),
          headers: const {'Accept': 'application/json', 'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(const Duration(seconds: 20));

    respStatus = resp.statusCode;
    respText = _prettyJsonIfPossible(resp.body);
    setState(() {});

    final j = await _parseJson(resp);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception(_formatApiError(j, resp.statusCode));
    }

    final a = _extractAuthData(j);
    if (a.isEmpty) throw Exception('自动登录缺少 data.auth_data');
    authData = a;

    final c = _extractSessionCookie(resp.headers['set-cookie']);
    if (c.isNotEmpty) cookie = c;

    await Store.saveAll(
      email: email,
      password: password,
      authData: authData,
      cookie: cookie,
      subscribeUrl: subscribeUrl,
    );
    setState(() {});
  }

  Future<void> _openAuthDialog({required bool forceLogin}) async {
    final res = await XBoardAuthDialog.show(
      context,
      initialEmail: email,
      initialPassword: password,
      forceLogin: forceLogin,
    );

    if (res == null) return;

    email = res.email;
    password = res.password;
    authData = res.authData;
    cookie = res.cookie;

    await Store.saveAll(
      email: email,
      password: password,
      authData: authData,
      cookie: cookie,
      subscribeUrl: subscribeUrl,
    );

    setState(() {});
    await fetchSubscribe(showToast: true);
  }

  Future<void> fetchSubscribe({required bool showToast}) async {
    if (authData.isEmpty) return;

    setState(() {
      loading = true;
      respStatus = null;
      respText = null;
    });

    try {
      final resp = await http
          .get(_apiV1('/user/getSubscribe'), headers: _headers())
          .timeout(const Duration(seconds: 15));

      respStatus = resp.statusCode;
      respText = _prettyJsonIfPossible(resp.body);
      setState(() {});

      final j = await _parseJson(resp);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception(_formatApiError(j, resp.statusCode));
      }

      final sub = _extractSubscribeUrl(j);
      if (sub.isNotEmpty) subscribeUrl = sub;

      final c = _extractSessionCookie(resp.headers['set-cookie']);
      if (c.isNotEmpty) cookie = c;

      lastFetchedAtMs = DateTime.now().millisecondsSinceEpoch;

      await Store.saveAll(
        email: email,
        password: password,
        authData: authData,
        cookie: cookie,
        subscribeUrl: subscribeUrl,
      );

      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已获取最新订阅')));
      }
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误：$e')));
      }
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> copySubscribe() async {
    if (subscribeUrl.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: subscribeUrl));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制订阅链接')));
  }

  Future<void> clearAll() async {
    await Store.clear();
    email = '';
    password = '';
    authData = '';
    cookie = '';
    subscribeUrl = '';
    respStatus = null;
    respText = null;
    lastFetchedAtMs = 0;
    setState(() {});

    if (mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openAuthDialog(forceLogin: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = authData.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('XBoard Client'),
        actions: [
          IconButton(
            tooltip: '认证',
            onPressed: loading ? null : () => _openAuthDialog(forceLogin: false),
            icon: const Icon(Icons.person),
          ),
          IconButton(
            tooltip: '刷新订阅',
            onPressed: (!loggedIn || loading) ? null : () => fetchSubscribe(showToast: true),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'clear') await clearAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('清空本地数据')),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            Card(
              child: ListTile(
                title: Text(loggedIn ? '已登录：$email' : '未登录'),
                subtitle: Text('最后刷新：${_fmtTime(lastFetchedAtMs)}'),
              ),
            ),
            const SizedBox(height: 12),

            const Text('订阅链接', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (subscribeUrl.isNotEmpty) ...[
              SelectableText(subscribeUrl),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: copySubscribe, child: const Text('复制订阅链接'))),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: (!loggedIn || loading) ? null : () => fetchSubscribe(showToast: true),
                      child: Text(loading ? '刷新中…' : '刷新订阅'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const Text('暂无（登录后会自动获取 /user/getSubscribe）'),
            ],

            const SizedBox(height: 18),
            if (respStatus != null) Text('HTTP Status: $respStatus', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (respText != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(respText!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
