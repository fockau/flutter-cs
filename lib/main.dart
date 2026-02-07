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
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF7A5CFF),
        brightness: Brightness.dark,
      ),
      // 默认直接进认证页
      home: const AuthGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// 启动路由：永远先去认证页
/// - 如果本地有 token，也可以选择自动尝试拉订阅后再进 Home（这里我给你做成：先认证页，避免你说的延迟感/跳动）
/// - 你想“有 token 就直接进 Home”的话我也可以给你改
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _goAuthFirst());
  }

  Future<void> _goAuthFirst() async {
    final s = LocalStore.I;

    final res = await Navigator.of(context).pushReplacement<AuthResult?>(
      AuthPage.route(
        force: true, // 启动必须登录：不可返回
        initialEmail: s.email,
        initialPassword: s.password,
      ),
    );

    if (res == null) return;

    await s.saveAuth(email: res.email, password: res.password, authData: res.authData, cookie: res.cookie);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
  }

  @override
  Widget build(BuildContext context) {
    // 这个页面不会被看到（只是过渡），给个纯黑占位
    return const Scaffold(backgroundColor: Colors.black);
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
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
    if (_authData.isNotEmpty) h['Authorization'] = _authData;
    if (_cookie.isNotEmpty) h['Cookie'] = _cookie;
    return h;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchSubscribe());
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
      final j = jsonDecode(resp.body);

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('HTTP ${resp.statusCode}: ${j is Map ? (j['message'] ?? resp.body) : resp.body}');
      }

      if (j is! Map) throw Exception('返回不是对象');
      final data = j['data'];
      if (data is! Map) throw Exception('data 不是对象');

      setState(() => subscribeData = Map<String, dynamic>.from(data));
    } catch (e) {
      setState(() => lastError = '获取订阅失败：$e');

      final es = e.toString();
      if (es.contains('403') || es.contains('未登录') || es.contains('登陆已过期')) {
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
          IconButton(onPressed: busy ? null : _fetchSubscribe, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: busy ? null : _logout, icon: const Icon(Icons.logout)),
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
                    if (busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator(minHeight: 3)),
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
