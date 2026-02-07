import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'XBoard API 工具',
      theme: ThemeData(useMaterial3: true),
      home: const Home(),
    );
  }
}

/// ====== 本地持久化配置模型 ======
enum AuthMode { bearer, plain }

class PersistedConfig {
  final String baseUrl;
  final String token;
  final AuthMode authMode;
  final String fixedHeaderName;
  final String fixedHeaderValue;

  const PersistedConfig({
    required this.baseUrl,
    required this.token,
    required this.authMode,
    required this.fixedHeaderName,
    required this.fixedHeaderValue,
  });

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'token': token,
        'authMode': authMode.name,
        'fixedHeaderName': fixedHeaderName,
        'fixedHeaderValue': fixedHeaderValue,
      };

  static PersistedConfig? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final base = (j['baseUrl'] ?? '').toString();
    final token = (j['token'] ?? '').toString();
    if (base.isEmpty || token.isEmpty) return null;

    final modeStr = (j['authMode'] ?? 'bearer').toString();
    final mode = (modeStr == 'plain') ? AuthMode.plain : AuthMode.bearer;

    return PersistedConfig(
      baseUrl: base,
      token: token,
      authMode: mode,
      fixedHeaderName: (j['fixedHeaderName'] ?? '').toString(),
      fixedHeaderValue: (j['fixedHeaderValue'] ?? '').toString(),
    );
  }
}

class Store {
  static const _k = 'xboard_config';

  static Future<PersistedConfig?> load() async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(_k);
    if (s == null || s.isEmpty) return null;
    try {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic>) return PersistedConfig.fromJson(j);
    } catch (_) {}
    return null;
  }

  static Future<void> save(PersistedConfig cfg) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k, jsonEncode(cfg.toJson()));
  }

  static Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_k);
  }
}

/// ====== 通用 HTTP 请求 ======
enum HttpMethod { get, post, put, delete }

String _normBaseUrl(String s) {
  s = s.trim();
  while (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
}

Map<String, String> _headersFromCfg(PersistedConfig cfg) {
  final h = <String, String>{
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  if (cfg.fixedHeaderName.isNotEmpty && cfg.fixedHeaderValue.isNotEmpty) {
    h[cfg.fixedHeaderName] = cfg.fixedHeaderValue;
  }

  // Authorization
  final auth = (cfg.authMode == AuthMode.bearer) ? 'Bearer ${cfg.token}' : cfg.token;
  h['Authorization'] = auth;

  return h;
}

/// 登录接口兼容解析 token：{data:{token}} 或 {token}
String _extractToken(dynamic loginJson) {
  if (loginJson is Map) {
    final data = loginJson['data'];
    if (data is Map && data['token'] != null) return '${data['token']}';
    if (loginJson['token'] != null) return '${loginJson['token']}';
  }
  return '';
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

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  // 登录区
  final baseUrlCtrl = TextEditingController(text: 'https://example.com');
  final emailCtrl = TextEditingController();
  final pwdCtrl = TextEditingController();

  AuthMode authMode = AuthMode.bearer; // 登录后保存（默认 Bearer）
  final fixedHeaderNameCtrl = TextEditingController(); // 例如 hasi
  final fixedHeaderValueCtrl = TextEditingController(); // 值

  // API 调用区
  HttpMethod method = HttpMethod.get;
  final pathCtrl = TextEditingController(text: '/api/v1/user/getSubscribe');
  final bodyCtrl = TextEditingController(text: '{\n  \n}');
  String? responseText;
  int? responseStatus;
  bool loading = false;

  PersistedConfig? cfg;

  @override
  void initState() {
    super.initState();
    _loadCfg();
  }

  @override
  void dispose() {
    baseUrlCtrl.dispose();
    emailCtrl.dispose();
    pwdCtrl.dispose();
    fixedHeaderNameCtrl.dispose();
    fixedHeaderValueCtrl.dispose();
    pathCtrl.dispose();
    bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCfg() async {
    final c = await Store.load();
    if (c != null) {
      baseUrlCtrl.text = c.baseUrl;
      authMode = c.authMode;
      fixedHeaderNameCtrl.text = c.fixedHeaderName;
      fixedHeaderValueCtrl.text = c.fixedHeaderValue;
    }
    setState(() => cfg = c);
  }

  Future<void> _saveCfg(PersistedConfig c) async {
    await Store.save(c);
    setState(() => cfg = c);
  }

  Future<void> loginAndPersist() async {
    setState(() {
      loading = true;
      responseText = null;
      responseStatus = null;
    });

    try {
      final base = _normBaseUrl(baseUrlCtrl.text);
      final email = emailCtrl.text.trim();
      final pwd = pwdCtrl.text;

      if (!base.startsWith('http://') && !base.startsWith('https://')) {
        throw Exception('baseUrl 必须以 http:// 或 https:// 开头');
      }
      if (email.isEmpty || pwd.isEmpty) {
        throw Exception('请输入邮箱和密码');
      }

      final h = <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      };

      final fhName = fixedHeaderNameCtrl.text.trim();
      final fhValue = fixedHeaderValueCtrl.text.trim();
      if (fhName.isNotEmpty && fhValue.isNotEmpty) {
        h[fhName] = fhValue;
      }

      final uri = Uri.parse('$base/api/v1/passport/auth/login');
      final resp = await http
          .post(uri, headers: h, body: jsonEncode({'email': email, 'password': pwd}))
          .timeout(const Duration(seconds: 15));

      responseStatus = resp.statusCode;
      responseText = _prettyJsonIfPossible(resp.body);

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('登录失败：HTTP ${resp.statusCode}');
      }

      final j = jsonDecode(resp.body);
      final t = _extractToken(j);
      if (t.isEmpty) {
        throw Exception('登录成功但未解析到 token（请检查后端返回结构）');
      }

      final newCfg = PersistedConfig(
        baseUrl: base,
        token: t,
        authMode: authMode,
        fixedHeaderName: fhName,
        fixedHeaderValue: fhValue,
      );

      await _saveCfg(newCfg);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('登录成功，已保存本地')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误：$e')));
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> callApi() async {
    final c = cfg;
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先登录并保存 token')));
      return;
    }

    setState(() {
      loading = true;
      responseText = null;
      responseStatus = null;
    });

    try {
      final base = _normBaseUrl(c.baseUrl);
      final path = pathCtrl.text.trim();
      if (!path.startsWith('/')) {
        throw Exception('路径必须以 / 开头，例如 /api/v1/user/getSubscribe');
      }

      final uri = Uri.parse('$base$path');
      final h = _headersFromCfg(c);

      http.Response resp;
      switch (method) {
        case HttpMethod.get:
          resp = await http.get(uri, headers: h).timeout(const Duration(seconds: 20));
          break;
        case HttpMethod.delete:
          resp = await http.delete(uri, headers: h).timeout(const Duration(seconds: 20));
          break;
        case HttpMethod.post:
          resp = await http
              .post(uri, headers: h, body: bodyCtrl.text.isEmpty ? '{}' : bodyCtrl.text)
              .timeout(const Duration(seconds: 20));
          break;
        case HttpMethod.put:
          resp = await http
              .put(uri, headers: h, body: bodyCtrl.text.isEmpty ? '{}' : bodyCtrl.text)
              .timeout(const Duration(seconds: 20));
          break;
      }

      setState(() {
        responseStatus = resp.statusCode;
        responseText = _prettyJsonIfPossible(resp.body);
      });
    } catch (e) {
      setState(() => responseText = 'Exception: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> updateAuthMode(AuthMode m) async {
    setState(() => authMode = m);
    final c = cfg;
    if (c != null) {
      await _saveCfg(PersistedConfig(
        baseUrl: c.baseUrl,
        token: c.token,
        authMode: m,
        fixedHeaderName: c.fixedHeaderName,
        fixedHeaderValue: c.fixedHeaderValue,
      ));
    }
  }

  Future<void> clearLocal() async {
    await Store.clear();
    setState(() {
      cfg = null;
      responseText = null;
      responseStatus = null;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空本地保存')));
  }

  @override
  Widget build(BuildContext context) {
    final saved = cfg != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('XBoard API 工具'),
        actions: [
          IconButton(
            tooltip: '清空本地保存',
            onPressed: loading ? null : clearLocal,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            // ===== 登录区 =====
            const Text('登录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: baseUrlCtrl,
              decoration: const InputDecoration(labelText: '面板域名（例如 https://example.com）'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: '邮箱'),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pwdCtrl,
              decoration: const InputDecoration(labelText: '密码'),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Authorization 模式：'),
                const SizedBox(width: 8),
                DropdownButton<AuthMode>(
                  value: authMode,
                  onChanged: loading ? null : (v) => v == null ? null : updateAuthMode(v),
                  items: const [
                    DropdownMenuItem(value: AuthMode.bearer, child: Text('Bearer token')),
                    DropdownMenuItem(value: AuthMode.plain, child: Text('Plain token')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: fixedHeaderNameCtrl,
                    decoration: const InputDecoration(labelText: '固定 Header 名（可选，例如 hasi）'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: fixedHeaderValueCtrl,
                    decoration: const InputDecoration(labelText: '固定 Header 值（可选）'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : loginAndPersist,
                child: Text(loading ? '处理中...' : '登录并保存到本地'),
              ),
            ),
            if (saved) ...[
              const SizedBox(height: 6),
              const Text('✅ 已保存 token（重启 App 仍然有效）', style: TextStyle(color: Colors.green)),
            ],

            const Divider(height: 32),

            // ===== API 调用区 =====
            const Text('自定义 API 请求', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(
              children: [
                DropdownButton<HttpMethod>(
                  value: method,
                  onChanged: loading ? null : (v) => setState(() => method = v ?? HttpMethod.get),
                  items: const [
                    DropdownMenuItem(value: HttpMethod.get, child: Text('GET')),
                    DropdownMenuItem(value: HttpMethod.post, child: Text('POST')),
                    DropdownMenuItem(value: HttpMethod.put, child: Text('PUT')),
                    DropdownMenuItem(value: HttpMethod.delete, child: Text('DELETE')),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: pathCtrl,
                    decoration: const InputDecoration(labelText: '路径（例如 /api/v1/user/getSubscribe）'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (method == HttpMethod.post || method == HttpMethod.put) ...[
              TextField(
                controller: bodyCtrl,
                decoration: const InputDecoration(
                  labelText: 'JSON Body（POST/PUT 用）',
                  alignLabelWithHint: true,
                ),
                minLines: 6,
                maxLines: 12,
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: (!saved || loading) ? null : callApi,
                child: Text(loading ? '请求中...' : '发送请求并输出返回'),
              ),
            ),

            const SizedBox(height: 16),
            if (responseStatus != null)
              Text('HTTP Status: $responseStatus', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (responseText != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(responseText!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
