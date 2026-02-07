import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

enum HttpMethod { get, post, put, delete }

class Store {
  static const _kBaseUrl = 'baseUrl';
  static const _kAuthData = 'authData'; // ✅ 保存完整的 "Bearer xxx"
  static const _kCookie = 'cookie'; // 可选：保存 server_name_session=...
  static const _kLastSubscribeUrl = 'lastSubscribeUrl';

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  static Future<void> saveBaseUrl(String v) async => (await _sp()).setString(_kBaseUrl, v);
  static Future<void> saveAuthData(String v) async => (await _sp()).setString(_kAuthData, v);
  static Future<void> saveCookie(String v) async => (await _sp()).setString(_kCookie, v);
  static Future<void> saveLastSubscribeUrl(String v) async => (await _sp()).setString(_kLastSubscribeUrl, v);

  static Future<String> getBaseUrl() async => (await _sp()).getString(_kBaseUrl) ?? '';
  static Future<String> getAuthData() async => (await _sp()).getString(_kAuthData) ?? '';
  static Future<String> getCookie() async => (await _sp()).getString(_kCookie) ?? '';
  static Future<String> getLastSubscribeUrl() async => (await _sp()).getString(_kLastSubscribeUrl) ?? '';

  static Future<void> clear() async {
    final sp = await _sp();
    await sp.remove(_kBaseUrl);
    await sp.remove(_kAuthData);
    await sp.remove(_kCookie);
    await sp.remove(_kLastSubscribeUrl);
  }
}

String _normBaseUrl(String s) {
  s = s.trim();
  while (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
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

/// 从登录返回里提取 auth_data：{data:{auth_data:"Bearer ..."}}
String _extractAuthData(dynamic loginJson) {
  if (loginJson is Map) {
    final data = loginJson['data'];
    if (data is Map && data['auth_data'] != null) return '${data['auth_data']}';
  }
  return '';
}

/// 从 getSubscribe 返回里提取 subscribe_url：{data:{subscribe_url:"..."}}
String _extractSubscribeUrl(dynamic j) {
  if (j is Map) {
    final data = j['data'];
    if (data is Map && data['subscribe_url'] != null) return '${data['subscribe_url']}';
  }
  return '';
}

/// 从 set-cookie 提取 server_name_session=...
String _extractSessionCookie(String? setCookie) {
  if (setCookie == null || setCookie.isEmpty) return '';
  final m = RegExp(r'(server_name_session=[^;]+)').firstMatch(setCookie);
  return m?.group(1) ?? '';
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

  // 自定义请求区
  HttpMethod method = HttpMethod.get;
  final pathCtrl = TextEditingController(text: '/api/v1/user/getSubscribe');
  final bodyCtrl = TextEditingController(text: '{\n  \n}');

  bool loading = false;

  String? authData; // "Bearer xxx"
  String? lastSubscribeUrl;

  int? respStatus;
  String? respText;

  @override
  void initState() {
    super.initState();
    _loadLocal();
  }

  @override
  void dispose() {
    baseUrlCtrl.dispose();
    emailCtrl.dispose();
    pwdCtrl.dispose();
    pathCtrl.dispose();
    bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocal() async {
    final base = await Store.getBaseUrl();
    final a = await Store.getAuthData();
    final sub = await Store.getLastSubscribeUrl();

    if (base.isNotEmpty) baseUrlCtrl.text = base;

    setState(() {
      authData = a.isEmpty ? null : a;
      lastSubscribeUrl = sub.isEmpty ? null : sub;
    });

    // 有 authData 就自动刷新一次订阅
    if (a.isNotEmpty && base.isNotEmpty) {
      await fetchSubscribe(showToast: false);
    }
  }

  Map<String, String> _commonHeaders({bool json = true}) {
    final h = <String, String>{
      'Accept': 'application/json',
    };
    if (json) h['Content-Type'] = 'application/json';

    // ✅ 必须：用 auth_data 原样作为 Authorization
    final a = authData;
    if (a != null && a.isNotEmpty) {
      h['Authorization'] = a;
    }

    // 可选：带上会话 cookie（某些站点会检查）
    // 这不会影响你现在的站点，即使不需要也没事
    // 如果你不想带，可以删掉下面三行
    // ignore: unused_local_variable
    return h;
  }

  Future<void> loginAndPersist() async {
    setState(() {
      loading = true;
      respStatus = null;
      respText = null;
    });

    try {
      final base = _normBaseUrl(baseUrlCtrl.text);
      final email = emailCtrl.text.trim();
      final pwd = pwdCtrl.text;

      if (!base.startsWith('http://') && !base.startsWith('https://')) {
        throw Exception('面板域名必须以 http:// 或 https:// 开头');
      }
      if (email.isEmpty || pwd.isEmpty) {
        throw Exception('请输入邮箱和密码');
      }

      final uri = Uri.parse('$base/api/v1/passport/auth/login');
      final resp = await http
          .post(
            uri,
            headers: {'Accept': 'application/json', 'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': pwd}),
          )
          .timeout(const Duration(seconds: 15));

      setState(() {
        respStatus = resp.statusCode;
        respText = _prettyJsonIfPossible(resp.body);
      });

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('登录失败：HTTP ${resp.statusCode}');
      }

      final j = jsonDecode(resp.body);
      final a = _extractAuthData(j);
      if (a.isEmpty) {
        throw Exception('登录成功但未找到 data.auth_data（后端返回结构与预期不一致）');
      }

      // 保存 baseUrl + authData
      await Store.saveBaseUrl(base);
      await Store.saveAuthData(a);

      // 保存 cookie（可选）
      final cookie = _extractSessionCookie(resp.headers['set-cookie']);
      if (cookie.isNotEmpty) await Store.saveCookie(cookie);

      setState(() {
        authData = a;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('登录成功，已保存 auth_data')));

      // 登录后拉一次订阅并保存
      await fetchSubscribe(showToast: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误：$e')));
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> fetchSubscribe({bool showToast = false}) async {
    setState(() {
      loading = true;
      respStatus = null;
      respText = null;
    });

    try {
      final base = _normBaseUrl(baseUrlCtrl.text);
      final a = authData ?? await Store.getAuthData();
      if (a.isEmpty) throw Exception('未登录：请先登录');

      // headers：Authorization=auth_data
      final headers = <String, String>{
        'Accept': 'application/json',
        'Authorization': a,
      };

      // 可选：带 cookie
      final cookie = await Store.getCookie();
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;

      final uri = Uri.parse('$base/api/v1/user/getSubscribe');
      final resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));

      setState(() {
        respStatus = resp.statusCode;
        respText = _prettyJsonIfPossible(resp.body);
      });

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('获取订阅失败：HTTP ${resp.statusCode}');
      }

      final j = jsonDecode(resp.body);
      final sub = _extractSubscribeUrl(j);
      if (sub.isEmpty) throw Exception('返回里未找到 data.subscribe_url');

      await Store.saveLastSubscribeUrl(sub);
      setState(() => lastSubscribeUrl = sub);

      if (showToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已获取最新订阅链接')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('错误：$e')));
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> callApi() async {
    final base = _normBaseUrl(baseUrlCtrl.text);
    final path = pathCtrl.text.trim();
    final a = authData ?? await Store.getAuthData();
    if (a.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先登录获取 auth_data')));
      return;
    }
    if (!path.startsWith('/')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('路径必须以 / 开头')));
      return;
    }

    setState(() {
      loading = true;
      respStatus = null;
      respText = null;
    });

    try {
      final uri = Uri.parse('$base$path');
      final headers = <String, String>{
        'Accept': 'application/json',
        'Authorization': a, // ✅ auth_data 原样
        'Content-Type': 'application/json',
      };
      final cookie = await Store.getCookie();
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;

      http.Response resp;
      switch (method) {
        case HttpMethod.get:
          resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 20));
          break;
        case HttpMethod.delete:
          resp = await http.delete(uri, headers: headers).timeout(const Duration(seconds: 20));
          break;
        case HttpMethod.post:
          resp = await http
              .post(uri, headers: headers, body: bodyCtrl.text.isEmpty ? '{}' : bodyCtrl.text)
              .timeout(const Duration(seconds: 20));
          break;
        case HttpMethod.put:
          resp = await http
              .put(uri, headers: headers, body: bodyCtrl.text.isEmpty ? '{}' : bodyCtrl.text)
              .timeout(const Duration(seconds: 20));
          break;
      }

      setState(() {
        respStatus = resp.statusCode;
        respText = _prettyJsonIfPossible(resp.body);
      });
    } catch (e) {
      setState(() => respText = 'Exception: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> copySubscribe() async {
    final s = lastSubscribeUrl;
    if (s == null || s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制订阅链接')));
  }

  Future<void> clearLocal() async {
    await Store.clear();
    setState(() {
      authData = null;
      lastSubscribeUrl = null;
      respStatus = null;
      respText = null;
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空本地保存')));
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = (authData != null && authData!.isNotEmpty);

    return Scaffold(
      appBar: AppBar(
        title: const Text('XBoard API 工具'),
        actions: [
          IconButton(
            tooltip: '刷新订阅',
            onPressed: loading ? null : () => fetchSubscribe(showToast: true),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '清空本地',
            onPressed: loading ? null : clearLocal,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
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
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : loginAndPersist,
                child: Text(loading ? '处理中...' : '登录并保存到本地（使用 auth_data）'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              loggedIn ? '✅ 已保存 auth_data（重启 App 仍然有效）' : '未登录',
              style: TextStyle(color: loggedIn ? Colors.green : Colors.black54),
            ),

            const Divider(height: 28),

            const Text('订阅链接', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (lastSubscribeUrl != null) ...[
              SelectableText(lastSubscribeUrl!),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: copySubscribe,
                  child: const Text('复制订阅链接'),
                ),
              ),
            ] else ...[
              const Text('暂无（登录后点右上角刷新或直接请求 getSubscribe）'),
            ],

            const Divider(height: 28),

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
                onPressed: (!loggedIn || loading) ? null : callApi,
                child: Text(loading ? '请求中...' : '发送请求并输出返回'),
              ),
            ),

            const SizedBox(height: 16),
            if (respStatus != null)
              Text('HTTP Status: $respStatus', style: const TextStyle(fontWeight: FontWeight.w700)),
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
