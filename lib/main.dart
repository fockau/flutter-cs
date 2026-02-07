import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'auth_page.dart';
import 'config_manager.dart';
import 'local_store.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalStore.I.init();
  runApp(const XBoardClientApp());
}

class XBoardClientApp extends StatelessWidget {
  const XBoardClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'King',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF7A5CFF),
      ),
      home: const BootGate(),
    );
  }
}

/// 启动逻辑：
/// 1) 本地有 token/auth_data => 自动请求 /user/getSubscribe
///    - 成功：直接进 HomePage（带首次订阅数据，避免再请求一次）
///    - 失败/403：清理 token -> 进 AuthPage（force=true）
/// 2) 本地无 token => 直接进 AuthPage（force=true）
class BootGate extends StatefulWidget {
  const BootGate({super.key});

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final s = LocalStore.I;
    final hasToken = s.authData.trim().isNotEmpty;

    if (hasToken) {
      final firstData = await _tryFetchSubscribeWithSavedAuth();
      if (firstData != null) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => HomePage(initialSubscribeData: firstData)),
        );
        return;
      }
      // token 失效/异常：走认证
    }

    await _goAuth(force: true);
  }

  Future<Map<String, dynamic>?> _tryFetchSubscribeWithSavedAuth() async {
    try {
      await ConfigManager.I.refreshRemoteConfigAndRace();

      final headers = <String, String>{'Accept': 'application/json'};
      final auth = LocalStore.I.authData.trim();
      final cookie = LocalStore.I.cookie.trim();
      if (auth.isNotEmpty) headers['Authorization'] = auth;
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;

      final uri = ConfigManager.I.api('/user/getSubscribe');
      final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 18));

      dynamic j;
      try {
        j = jsonDecode(resp.body);
      } catch (_) {
        throw Exception('返回不是 JSON：${resp.body}');
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final msg = (j is Map && j['message'] != null) ? j['message'].toString() : 'HTTP ${resp.statusCode}';
        throw Exception('$msg');
      }

      if (j is! Map) throw Exception('返回不是对象');
      final data = j['data'];
      if (data is! Map) throw Exception('data 不是对象');

      return Map<String, dynamic>.from(data);
    } catch (e) {
      final es = e.toString();
      final needReauth =
          es.contains('403') || es.contains('未登录') || es.contains('登陆已过期') || es.contains('登录已过期');

      if (needReauth) {
        await LocalStore.I.clearAuth();
      }
      return null;
    }
  }

  Future<void> _goAuth({required bool force}) async {
    final s = LocalStore.I;

    final res = await Navigator.of(context).pushReplacement(
      AuthPage.route(
        force: force,
        initialEmail: s.email,
        initialPassword: s.password,
      ),
    ) as AuthResult?;

    if (res == null) return;

    await s.saveAuth(
      email: res.email,
      password: res.password,
      authData: res.authData,
      cookie: res.cookie,
    );

    // 登录后：立即拉一次订阅（确保主页显示最新）
    Map<String, dynamic>? first;
    try {
      first = await _tryFetchSubscribeWithSavedAuth();
    } catch (_) {}

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomePage(initialSubscribeData: first)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 纯黑启动占位，减少“跳一下”的观感
    return const Scaffold(backgroundColor: Colors.black);
  }
}

/// 登录后主页：显示订阅链接 + 原始 JSON，支持刷新与退出
class HomePage extends StatefulWidget {
  final Map<String, dynamic>? initialSubscribeData;
  const HomePage({super.key, this.initialSubscribeData});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool busy = false;
  String? lastError;
  Map<String, dynamic>? subscribeData;

  String get _authData => LocalStore.I.authData;
  String get _cookie => LocalStore.I.cookie;

  Map<String, String> _authHeaders() {
    final h = <String, String>{'Accept': 'application/json'};
    if (_authData.trim().isNotEmpty) h['Authorization'] = _authData.trim();
    if (_cookie.trim().isNotEmpty) h['Cookie'] = _cookie.trim();
    return h;
  }

  @override
  void initState() {
    super.initState();
    // 使用启动时预取的数据，避免进主页又空一下
    subscribeData = widget.initialSubscribeData;

    // 如果没有预取数据，再自动拉一次
    if (subscribeData == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fetchSubscribe());
    }
  }

  Future<void> _fetchSubscribe() async {
    setState(() {
      busy = true;
      lastError = null;
    });

    try {
      await ConfigManager.I.refreshRemoteConfigAndRace();

      final uri = ConfigManager.I.api('/user/getSubscribe');
      final resp = await http.get(uri, headers: _authHeaders()).timeout(const Duration(seconds: 20));

      dynamic j;
      try {
        j = jsonDecode(resp.body);
      } catch (_) {
        throw Exception('返回不是 JSON：${resp.body}');
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final msg = (j is Map && j['message'] != null) ? j['message'].toString() : 'HTTP ${resp.statusCode}';
        throw Exception('$msg\n${resp.body}');
      }

      if (j is! Map) throw Exception('返回不是对象');
      final data = j['data'];
      if (data is! Map) throw Exception('data 不是对象');

      setState(() => subscribeData = Map<String, dynamic>.from(data));
    } catch (e) {
      setState(() => lastError = '获取订阅失败：$e');

      final es = e.toString();
      final needReauth =
          es.contains('403') || es.contains('未登录') || es.contains('登陆已过期') || es.contains('登录已过期');

      if (needReauth) {
        await LocalStore.I.clearAuth();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(AuthPage.route(force: true));
      }
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _logout() async {
    await LocalStore.I.clearAuth();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(AuthPage.route(force: true));
  }

  @override
  Widget build(BuildContext context) {
    final subUrl = (subscribeData?['subscribe_url'] ?? '').toString();

    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅信息'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: busy ? null : _fetchSubscribe,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '退出登录',
            onPressed: busy ? null : _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('订阅链接', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 10),
                    SelectableText(subUrl.isEmpty ? '暂无（请刷新）' : subUrl),
                    if (busy) ...[
                      const SizedBox(height: 10),
                      const LinearProgressIndicator(minHeight: 3),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(subscribeData ?? {}),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ),
            if (lastError != null) ...[
              const SizedBox(height: 12),
              Text(lastError!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
