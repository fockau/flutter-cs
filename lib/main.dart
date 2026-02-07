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

/// ==================== 历史登录数据模型 ====================
class LoginProfile {
  final String id; // 用于唯一标识（简单用 baseUrl|email 的 hash）
  final String baseUrl;
  final String email;
  final String authData; // "Bearer xxxx"
  final String cookie; // server_name_session=...
  final String lastSubscribeUrl;
  final int savedAtMs; // 时间戳

  const LoginProfile({
    required this.id,
    required this.baseUrl,
    required this.email,
    required this.authData,
    required this.cookie,
    required this.lastSubscribeUrl,
    required this.savedAtMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'baseUrl': baseUrl,
        'email': email,
        'authData': authData,
        'cookie': cookie,
        'lastSubscribeUrl': lastSubscribeUrl,
        'savedAtMs': savedAtMs,
      };

  static LoginProfile? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = (j['id'] ?? '').toString();
    final baseUrl = (j['baseUrl'] ?? '').toString();
    final email = (j['email'] ?? '').toString();
    final authData = (j['authData'] ?? '').toString();
    if (id.isEmpty || baseUrl.isEmpty || authData.isEmpty) return null;
    return LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      authData: authData,
      cookie: (j['cookie'] ?? '').toString(),
      lastSubscribeUrl: (j['lastSubscribeUrl'] ?? '').toString(),
      savedAtMs: int.tryParse((j['savedAtMs'] ?? '0').toString()) ?? 0,
    );
  }

  LoginProfile copyWith({
    String? cookie,
    String? lastSubscribeUrl,
    int? savedAtMs,
    String? authData,
  }) {
    return LoginProfile(
      id: id,
      baseUrl: baseUrl,
      email: email,
      authData: authData ?? this.authData,
      cookie: cookie ?? this.cookie,
      lastSubscribeUrl: lastSubscribeUrl ?? this.lastSubscribeUrl,
      savedAtMs: savedAtMs ?? this.savedAtMs,
    );
  }
}

String _makeProfileId(String baseUrl, String email) {
  // 够用即可：避免重复（同站点同邮箱覆盖）
  final s = '${baseUrl.toLowerCase()}|${email.toLowerCase()}';
  return s.codeUnits.fold<int>(0, (a, b) => (a * 131 + b) & 0x7fffffff).toString();
}

/// ==================== 本地存储 ====================
class Store {
  static const _kCurrentBaseUrl = 'current_baseUrl';
  static const _kCurrentAuthData = 'current_authData';
  static const _kCurrentCookie = 'current_cookie';
  static const _kCurrentLastSubscribeUrl = 'current_lastSubscribeUrl';
  static const _kProfiles = 'profiles_json'; // List<LoginProfile>

  static Future<SharedPreferences> _sp() => SharedPreferences.getInstance();

  static Future<void> saveCurrent({
    required String baseUrl,
    required String authData,
    required String cookie,
    required String lastSubscribeUrl,
  }) async {
    final sp = await _sp();
    await sp.setString(_kCurrentBaseUrl, baseUrl);
    await sp.setString(_kCurrentAuthData, authData);
    await sp.setString(_kCurrentCookie, cookie);
    await sp.setString(_kCurrentLastSubscribeUrl, lastSubscribeUrl);
  }

  static Future<String> getCurrentBaseUrl() async => (await _sp()).getString(_kCurrentBaseUrl) ?? '';
  static Future<String> getCurrentAuthData() async => (await _sp()).getString(_kCurrentAuthData) ?? '';
  static Future<String> getCurrentCookie() async => (await _sp()).getString(_kCurrentCookie) ?? '';
  static Future<String> getCurrentLastSubscribeUrl() async =>
      (await _sp()).getString(_kCurrentLastSubscribeUrl) ?? '';

  static Future<List<LoginProfile>> loadProfiles() async {
    final sp = await _sp();
    final s = sp.getString(_kProfiles);
    if (s == null || s.isEmpty) return [];
    try {
      final j = jsonDecode(s);
      if (j is List) {
        final out = <LoginProfile>[];
        for (final it in j) {
          final p = LoginProfile.fromJson(it);
          if (p != null) out.add(p);
        }
        // 新的在前
        out.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
        return out;
      }
    } catch (_) {}
    return [];
  }

  static Future<void> saveProfiles(List<LoginProfile> profiles) async {
    final sp = await _sp();
    final list = profiles.map((e) => e.toJson()).toList();
    await sp.setString(_kProfiles, jsonEncode(list));
  }

  /// 新增或覆盖（同 id 覆盖）
  static Future<void> upsertProfile(LoginProfile p) async {
    final profiles = await loadProfiles();
    final idx = profiles.indexWhere((x) => x.id == p.id);
    if (idx >= 0) {
      profiles[idx] = p;
    } else {
      profiles.add(p);
    }
    profiles.sort((a, b) => b.savedAtMs.compareTo(a.savedAtMs));
    await saveProfiles(profiles);
  }

  static Future<void> deleteProfile(String id) async {
    final profiles = await loadProfiles();
    profiles.removeWhere((x) => x.id == id);
    await saveProfiles(profiles);
  }

  static Future<void> clearProfiles() async {
    final sp = await _sp();
    await sp.remove(_kProfiles);
  }

  static Future<void> clearAll() async {
    final sp = await _sp();
    await sp.remove(_kCurrentBaseUrl);
    await sp.remove(_kCurrentAuthData);
    await sp.remove(_kCurrentCookie);
    await sp.remove(_kCurrentLastSubscribeUrl);
    await sp.remove(_kProfiles);
  }
}

/// ==================== UI 主页 ====================
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
  String? cookie; // server_name_session=...
  String? lastSubscribeUrl;

  int? respStatus;
  String? respText;

  List<LoginProfile> profiles = [];

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
    final base = await Store.getCurrentBaseUrl();
    final a = await Store.getCurrentAuthData();
    final c = await Store.getCurrentCookie();
    final sub = await Store.getCurrentLastSubscribeUrl();
    final ps = await Store.loadProfiles();

    if (base.isNotEmpty) baseUrlCtrl.text = base;

    setState(() {
      authData = a.isEmpty ? null : a;
      cookie = c.isEmpty ? null : c;
      lastSubscribeUrl = sub.isEmpty ? null : sub;
      profiles = ps;
    });

    // 有 authData 就自动刷新一次订阅
    if (a.isNotEmpty && base.isNotEmpty) {
      await fetchSubscribe(showToast: false);
    }
  }

  Future<void> _reloadProfiles() async {
    final ps = await Store.loadProfiles();
    setState(() => profiles = ps);
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

      final c = _extractSessionCookie(resp.headers['set-cookie']);

      // 先写当前
      await Store.saveCurrent(
        baseUrl: base,
        authData: a,
        cookie: c,
        lastSubscribeUrl: (lastSubscribeUrl ?? ''),
      );

      // 写历史（覆盖同站点同邮箱）
      final profile = LoginProfile(
        id: _makeProfileId(base, email),
        baseUrl: base,
        email: email,
        authData: a,
        cookie: c,
        lastSubscribeUrl: (lastSubscribeUrl ?? ''),
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await Store.upsertProfile(profile);

      setState(() {
        authData = a;
        cookie = c.isEmpty ? null : c;
      });
      await _reloadProfiles();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('登录成功，已保存到历史')));

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
      final a = authData ?? await Store.getCurrentAuthData();
      if (a.isEmpty) throw Exception('未登录：请先登录');

      final headers = <String, String>{
        'Accept': 'application/json',
        'Authorization': a, // ✅ auth_data 原样
      };

      // 可选带 cookie
      final c = cookie ?? await Store.getCurrentCookie();
      if (c.isNotEmpty) headers['Cookie'] = c;

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

      // 更新 cookie（有些接口也会刷新）
      final newCookie = _extractSessionCookie(resp.headers['set-cookie']);
      final finalCookie = newCookie.isNotEmpty ? newCookie : (c.isNotEmpty ? c : '');

      // 保存当前
      await Store.saveCurrent(baseUrl: base, authData: a, cookie: finalCookie, lastSubscribeUrl: sub);

      setState(() {
        lastSubscribeUrl = sub;
        cookie = finalCookie.isEmpty ? null : finalCookie;
      });

      // 同步更新历史里“当前站点+邮箱”的订阅链接/时间（如果找得到同 baseUrl/email）
      final email = emailCtrl.text.trim();
      final pid = _makeProfileId(base, email.isEmpty ? 'unknown' : email);
      final ps = await Store.loadProfiles();
      final idx = ps.indexWhere((x) => x.id == pid);
      if (idx >= 0) {
        final updated = ps[idx].copyWith(
          lastSubscribeUrl: sub,
          cookie: finalCookie,
          savedAtMs: DateTime.now().millisecondsSinceEpoch,
          authData: a,
        );
        ps[idx] = updated;
        await Store.saveProfiles(ps);
        await _reloadProfiles();
      }

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
    final a = authData ?? await Store.getCurrentAuthData();
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
        'Authorization': a,
        'Content-Type': 'application/json',
      };
      final c = cookie ?? await Store.getCurrentCookie();
      if (c.isNotEmpty) headers['Cookie'] = c;

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

  Future<void> clearAllLocal() async {
    await Store.clearAll();
    setState(() {
      authData = null;
      cookie = null;
      lastSubscribeUrl = null;
      respStatus = null;
      respText = null;
      profiles = [];
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空所有本地数据与历史')));
  }

  /// 选择某个历史账号
  Future<void> useProfile(LoginProfile p) async {
    baseUrlCtrl.text = p.baseUrl;
    emailCtrl.text = p.email;
    // 密码不保存（安全），留空
    pwdCtrl.text = '';

    setState(() {
      authData = p.authData;
      cookie = p.cookie.isEmpty ? null : p.cookie;
      lastSubscribeUrl = p.lastSubscribeUrl.isEmpty ? null : p.lastSubscribeUrl;
    });

    await Store.saveCurrent(
      baseUrl: p.baseUrl,
      authData: p.authData,
      cookie: p.cookie,
      lastSubscribeUrl: p.lastSubscribeUrl,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已切换到该历史账号，正在刷新订阅…')));
    await fetchSubscribe(showToast: false);
  }

  Future<void> deleteProfile(LoginProfile p) async {
    await Store.deleteProfile(p.id);
    await _reloadProfiles();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已删除该历史记录')));
  }

  Future<void> clearProfilesOnly() async {
    await Store.clearProfiles();
    await _reloadProfiles();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已清空历史记录')));
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
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
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) async {
              if (v == 'clear_profiles') await clearProfilesOnly();
              if (v == 'clear_all') await clearAllLocal();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear_profiles', child: Text('清空历史记录')),
              PopupMenuItem(value: 'clear_all', child: Text('清空全部数据（含当前登录）')),
            ],
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            // ===== 历史登录列表 =====
            Row(
              children: [
                const Expanded(
                  child: Text('历史登录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
                TextButton(
                  onPressed: loading || profiles.isEmpty ? null : clearProfilesOnly,
                  child: const Text('清空历史'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (profiles.isEmpty)
              const Text('暂无历史记录（登录一次就会自动保存）', style: TextStyle(color: Colors.black54))
            else
              ...profiles.map((p) {
                return Card(
                  child: ListTile(
                    title: Text('${p.email.isEmpty ? '(未记录邮箱)' : p.email}  ·  ${p.baseUrl}'),
                    subtitle: Text('保存时间：${_fmtTime(p.savedAtMs)}'
                        '${p.lastSubscribeUrl.isNotEmpty ? '\n订阅：${p.lastSubscribeUrl}' : ''}'),
                    isThreeLine: p.lastSubscribeUrl.isNotEmpty,
                    onTap: loading ? null : () => useProfile(p),
                    trailing: IconButton(
                      tooltip: '删除',
                      onPressed: loading ? null : () => deleteProfile(p),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                );
              }),

            const Divider(height: 28),

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
              decoration: const InputDecoration(labelText: '邮箱（用于历史记录标识）'),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pwdCtrl,
              decoration: const InputDecoration(labelText: '密码（不会保存）'),
              obscureText: true,
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : loginAndPersist,
                child: Text(loading ? '处理中...' : '登录并保存到历史（使用 auth_data）'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              loggedIn ? '✅ 当前已登录（auth_data 已保存）' : '未登录',
              style: TextStyle(color: loggedIn ? Colors.green : Colors.black54),
            ),

            const Divider(height: 28),

            // ===== 订阅链接 =====
            const Text('订阅链接', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (lastSubscribeUrl != null && lastSubscribeUrl!.isNotEmpty) ...[
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
              const Text('暂无（登录后点右上角刷新或请求 getSubscribe）'),
            ],

            const Divider(height: 28),

            // ===== 自定义 API 请求 =====
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
