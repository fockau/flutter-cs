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
      title: 'XBoard 订阅',
      theme: ThemeData(useMaterial3: true),
      home: const XBoardPage(),
    );
  }
}

class XBoardPage extends StatefulWidget {
  const XBoardPage({super.key});
  @override
  State<XBoardPage> createState() => _XBoardPageState();
}

class _XBoardPageState extends State<XBoardPage> {
  // ====== 可选：如果你后端需要固定 Header（防滥用）就在这里填 ======
  static const String? fixedHeaderName = null; // 例如 'hasi'
  static const String? fixedHeaderValue = null; // 例如 '18df203a-6abf-41ff-b10c-0be7b00f59a6'
  // ===================================================================

  // SharedPreferences keys
  static const _kBaseUrl = 'baseUrl';
  static const _kToken = 'token';
  static const _kSubscribeUrl = 'subscribeUrl';

  final baseUrlCtrl = TextEditingController(text: 'https://example.com');
  final emailCtrl = TextEditingController();
  final pwdCtrl = TextEditingController();

  bool loading = false;
  String? errorText;

  String? token;
  String? subscribeUrl;

  @override
  void initState() {
    super.initState();
    _loadLocalAndAutoFetch();
  }

  @override
  void dispose() {
    baseUrlCtrl.dispose();
    emailCtrl.dispose();
    pwdCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocalAndAutoFetch() async {
    final sp = await SharedPreferences.getInstance();
    final savedBase = sp.getString(_kBaseUrl);
    final savedToken = sp.getString(_kToken);
    final savedSub = sp.getString(_kSubscribeUrl);

    if (savedBase != null && savedBase.isNotEmpty) {
      baseUrlCtrl.text = savedBase;
    }
    setState(() {
      token = savedToken;
      subscribeUrl = savedSub;
    });

    // 有 token 就自动拉一次最新订阅
    if (savedToken != null && savedToken.isNotEmpty && savedBase != null && savedBase.isNotEmpty) {
      await fetchSubscribe(showSuccessToast: false);
    }
  }

  String _normBaseUrl(String s) {
    s = s.trim();
    while (s.endsWith('/')) s = s.substring(0, s.length - 1);
    return s;
  }

  Map<String, String> _commonHeaders() {
    final h = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (fixedHeaderName != null && fixedHeaderValue != null) {
      h[fixedHeaderName!] = fixedHeaderValue!;
    }
    return h;
  }

  String _extractToken(dynamic loginJson) {
    // 兼容：
    // A) {status:"success", data:{token:"..."}}
    // B) {token:"..."}
    if (loginJson is Map) {
      final data = loginJson['data'];
      if (data is Map && data['token'] != null) return '${data['token']}';
      if (loginJson['token'] != null) return '${loginJson['token']}';
    }
    return '';
  }

  String _extractSubscribeUrl(dynamic subJson) {
    // 兼容：
    // A) {status:"success", data:{subscribe_url:"..."}}
    // B) {subscribe_url:"..."}
    if (subJson is Map) {
      final data = subJson['data'];
      final Map<dynamic, dynamic> m = (data is Map) ? data : subJson;

      final v1 = m['subscribe_url'];
      if (v1 != null) return '$v1';

      // 兜底：有些后端叫 subscribeUrl
      final v2 = m['subscribeUrl'];
      if (v2 != null) return '$v2';
    }
    return '';
  }

  String _extractMessage(String body) {
    // 尽量把返回体里的 message 解析成可读中文
    try {
      final j = jsonDecode(body);
      if (j is Map && j['message'] != null) return '${j['message']}';
      if (j is Map && j['msg'] != null) return '${j['msg']}';
    } catch (_) {}
    return body;
  }

  Future<void> login() async {
    setState(() {
      loading = true;
      errorText = null;
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
          .post(uri, headers: _commonHeaders(), body: jsonEncode({'email': email, 'password': pwd}))
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('登录失败：HTTP ${resp.statusCode}\n${_extractMessage(resp.body)}');
      }

      final loginJson = jsonDecode(resp.body);
      final t = _extractToken(loginJson);
      if (t.isEmpty) {
        throw Exception('登录失败：返回中未找到 token\n${resp.body}');
      }

      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kBaseUrl, base);
      await sp.setString(_kToken, t);

      setState(() {
        token = t;
      });

      // 登录后马上拉一次订阅（并写入本地）
      await fetchSubscribe(showSuccessToast: true);
    } catch (e) {
      final msg = e.toString();
      // 让提示更友好
      if (msg.contains('Failed host lookup')) {
        setState(() => errorText = '域名解析失败：请确认域名填写正确、手机网络/DNS正常。\n\n原始错误：$msg');
      } else {
        setState(() => errorText = msg);
      }
    } finally {
      setState(() => loading = false);
    }
  }

  /// 获取最新订阅：先用 Bearer；若 401/403 则自动重试 plain token
  Future<void> fetchSubscribe({bool showSuccessToast = false}) async {
    setState(() {
      loading = true;
      errorText = null;
    });

    try {
      final sp = await SharedPreferences.getInstance();
      final base = _normBaseUrl(sp.getString(_kBaseUrl) ?? baseUrlCtrl.text);
      final t = sp.getString(_kToken) ?? token;

      if (t == null || t.isEmpty) {
        throw Exception('未登录：请先登录');
      }

      final uri = Uri.parse('$base/api/v1/user/getSubscribe');

      Future<http.Response> doReq(String authHeaderValue) {
        final h = _commonHeaders();
        h['Authorization'] = authHeaderValue;
        return http.get(uri, headers: h).timeout(const Duration(seconds: 15));
      }

      // 1) 先试 Bearer
      var resp = await doReq('Bearer $t');

      // 2) 如果 401/403，再试 plain token（很多 xboard/v2board 就是这种）
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        resp = await doReq(t);
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final msg = _extractMessage(resp.body);
        throw Exception('获取订阅失败：HTTP ${resp.statusCode}\n$msg');
      }

      final subJson = jsonDecode(resp.body);
      final sUrl = _extractSubscribeUrl(subJson);
      if (sUrl.isEmpty) {
        throw Exception('订阅返回中未找到 subscribe_url\n${resp.body}');
      }

      await sp.setString(_kSubscribeUrl, sUrl);
      await sp.setString(_kBaseUrl, base);

      setState(() {
        subscribeUrl = sUrl;
      });

      if (showSuccessToast && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已获取最新订阅链接')));
      }
    } catch (e) {
      setState(() => errorText = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> copySubscribeUrl() async {
    final s = subscribeUrl;
    if (s == null || s.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: s));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已复制订阅链接')));
  }

  Future<void> logoutClear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kToken);
    await sp.remove(_kSubscribeUrl);

    setState(() {
      token = null;
      subscribeUrl = null;
      errorText = null;
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已退出登录')));
  }

  @override
  Widget build(BuildContext context) {
    final sUrl = subscribeUrl;

    return Scaffold(
      appBar: AppBar(
        title: const Text('XBoard 登录取订阅链接'),
        actions: [
          IconButton(
            tooltip: '刷新订阅',
            onPressed: loading ? null : () => fetchSubscribe(showSuccessToast: true),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '清除登录',
            onPressed: loading ? null : logoutClear,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: baseUrlCtrl,
              decoration: const InputDecoration(labelText: '面板域名（例如 https://example.com）'),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: '邮箱'),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pwdCtrl,
              decoration: const InputDecoration(labelText: '密码'),
              obscureText: true,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : login,
                child: Text(loading ? '处理中...' : '登录并获取订阅链接'),
              ),
            ),
            const SizedBox(height: 12),
            if (errorText != null) ...[
              Text(errorText!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
            ],
            if (sUrl != null) ...[
              const Text('最新订阅链接：', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SelectableText(sUrl),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: copySubscribeUrl,
                  child: const Text('复制订阅链接'),
                ),
              ),
            ] else ...[
              const Text('未获取到订阅链接（如果你已登录，可点右上角刷新）。'),
            ],
          ],
        ),
      ),
    );
  }
}      errorText = null;
      token = null;
      subscribeUrl = null;
    });

    try {
      final base = _normBaseUrl(baseUrlCtrl.text);

      if (!base.startsWith('http://') && !base.startsWith('https://')) {
        throw Exception('面板域名必须以 http:// 或 https:// 开头');
      }
      if (emailCtrl.text.trim().isEmpty || pwdCtrl.text.isEmpty) {
        throw Exception('请输入邮箱和密码');
      }

      // ============ 1) 登录拿 token ============
      final loginUri = Uri.parse('$base/api/v1/passport/auth/login');
      final loginBody = jsonEncode({
        'email': emailCtrl.text.trim(),
        'password': pwdCtrl.text,
      });

      final loginResp = await http
          .post(loginUri, headers: _commonHeaders(), body: loginBody)
          .timeout(const Duration(seconds: 15));

      if (loginResp.statusCode < 200 || loginResp.statusCode >= 300) {
        throw Exception('登录失败：HTTP ${loginResp.statusCode}\n${loginResp.body}');
      }

      final loginJson = jsonDecode(loginResp.body);
      final t = _extractToken(loginJson);

      if (t.isEmpty) {
        throw Exception('登录失败：返回中未找到 token\n${loginResp.body}');
      }

      // ============ 2) 获取订阅信息 ============
      final subUri = Uri.parse('$base/api/v1/user/getSubscribe');

      final headers = _commonHeaders();
      // 默认 Bearer（最常见）：
      headers['Authorization'] = 'Bearer $t';

      // 如果你后端不是 Bearer，而是直接 token，改成下面这行：
      // headers['Authorization'] = t;

      final subResp =
          await http.get(subUri, headers: headers).timeout(const Duration(seconds: 15));

      if (subResp.statusCode < 200 || subResp.statusCode >= 300) {
        throw Exception('获取订阅失败：HTTP ${subResp.statusCode}\n${subResp.body}');
      }

      final subJson = jsonDecode(subResp.body);
      final sUrl = _extractSubscribeUrl(subJson);

      if (sUrl.isEmpty) {
        throw Exception('订阅返回中未找到 subscribe_url\n${subResp.body}');
      }

      setState(() {
        token = t;
        subscribeUrl = sUrl;
      });
    } catch (e) {
      setState(() => errorText = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> copySubscribeUrl() async {
    final s = subscribeUrl;
    if (s == null || s.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: s));
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制订阅链接')));
  }

  @override
  Widget build(BuildContext context) {
    final sUrl = subscribeUrl;

    return Scaffold(
      appBar: AppBar(
        title: const Text('XBoard 登录取订阅链接'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: baseUrlCtrl,
              decoration: const InputDecoration(
                labelText: '面板域名（例如 https://example.com）',
              ),
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(labelText: '邮箱'),
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pwdCtrl,
              decoration: const InputDecoration(labelText: '密码'),
              obscureText: true,
              autocorrect: false,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: loading ? null : loginAndFetchSubscribe,
                child: Text(loading ? '处理中...' : '登录并获取订阅链接'),
              ),
            ),
            if (errorText != null) ...[
              const SizedBox(height: 12),
              Text(
                errorText!,
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 16),
            if (sUrl != null) ...[
              const Text('最新订阅链接：', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SelectableText(sUrl),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: copySubscribeUrl,
                  child: const Text('复制订阅链接'),
                ),
              ),
            ] else ...[
              const Text('未获取到订阅链接（请先登录）。'),
            ],
          ],
        ),
      ),
    );
  }
}
