import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'XBoard 订阅',
      theme: ThemeData(useMaterial3: true),
      home: const OneFileXBoardPage(),
    );
  }
}

class OneFileXBoardPage extends StatefulWidget {
  const OneFileXBoardPage({super.key});

  @override
  State<OneFileXBoardPage> createState() => _OneFileXBoardPageState();
}

class _OneFileXBoardPageState extends State<OneFileXBoardPage> {
  // ====== 你只需要改这里：默认面板域名（不要以 / 结尾）======
  final baseUrlCtrl = TextEditingController(text: 'https://example.com');
  // =======================================================

  final emailCtrl = TextEditingController();
  final pwdCtrl = TextEditingController();

  bool loading = false;
  String? errorText;

  String? token;
  String? subscribeUrl;

  @override
  void dispose() {
    baseUrlCtrl.dispose();
    emailCtrl.dispose();
    pwdCtrl.dispose();
    super.dispose();
  }

  String _normBaseUrl(String s) {
    s = s.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Map<String, String> _commonHeaders() {
    return <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',

      // 如果你需要固定 Header（例如 hasi），取消注释并填值：
      // 'hasi': '18df203a-6abf-41ff-b10c-0be7b00f59a6',
    };
  }

  String _extractToken(dynamic loginJson) {
    // 兼容：
    // A) {status:"success", data:{token:"...", ...}}
    // B) {token:"...", user:{...}}
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

      // 兼容某些后端字段写法（以防万一）
      final v2 = m['subscribeUrl'];
      if (v2 != null) return '$v2';
    }
    return '';
  }

  Future<void> loginAndFetchSubscribe() async {
    setState(() {
      loading = true;
      errorText = null;
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
