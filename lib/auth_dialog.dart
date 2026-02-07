import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config.dart';

class AuthDialogResult {
  final String email;
  final String password;
  final String authData; // Bearer ...
  final String cookie;   // server_name_session=...

  const AuthDialogResult({
    required this.email,
    required this.password,
    required this.authData,
    required this.cookie,
  });
}

enum AuthTab { login, register, forgot }
enum EmailCodeScene { register, resetPassword }

extension _SceneExt on EmailCodeScene {
  String get value => this == EmailCodeScene.register ? 'register' : 'resetPassword';
  String get label => this == EmailCodeScene.register ? '注册' : '重置密码';
}

String _trimSlash(String s) {
  s = s.trim();
  while (s.endsWith('/')) s = s.substring(0, s.length - 1);
  return s;
}

Uri _apiV1(String pathUnderApiV1) {
  final api = _trimSlash(AppConfig.apiBaseUrl);
  if (!pathUnderApiV1.startsWith('/')) pathUnderApiV1 = '/$pathUnderApiV1';
  return Uri.parse('$api/api/v1$pathUnderApiV1');
}

String _extractAuthData(dynamic j) {
  if (j is Map) {
    final data = j['data'];
    if (data is Map && data['auth_data'] != null) return '${data['auth_data']}';
    if (data is Map && data['token'] != null) return 'Bearer ${data['token']}';
  }
  return '';
}

String _extractSessionCookie(String? setCookie) {
  if (setCookie == null || setCookie.isEmpty) return '';
  final m = RegExp(r'(server_name_session=[^;]+)').firstMatch(setCookie);
  return m?.group(1) ?? '';
}

class GuestConfig {
  final int isEmailVerify; // 0/1
  final List<String> emailSuffixes; // whitelist

  const GuestConfig({required this.isEmailVerify, required this.emailSuffixes});

  static GuestConfig? fromJson(dynamic j) {
    if (j is! Map) return null;
    final data = j['data'];
    if (data is! Map) return null;

    int toInt(dynamic v) {
      if (v is bool) return v ? 1 : 0;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    List<String> suffixes = [];
    final raw = data['email_whitelist_suffix'];
    if (raw is List) {
      suffixes = raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      suffixes = suffixes.toSet().toList();
      suffixes.sort();
    }

    return GuestConfig(
      isEmailVerify: toInt(data['is_email_verify']),
      emailSuffixes: suffixes,
    );
  }
}

class XBoardAuthDialog {
  static Future<AuthDialogResult?> show(
    BuildContext context, {
    String initialEmail = '',
    String initialPassword = '',
    bool forceLogin = false,
  }) {
    return showDialog<AuthDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AuthDialog(
        initialEmail: initialEmail,
        initialPassword: initialPassword,
        forceLogin: forceLogin,
      ),
    );
  }
}

class _AuthDialog extends StatefulWidget {
  final String initialEmail;
  final String initialPassword;
  final bool forceLogin;

  const _AuthDialog({
    required this.initialEmail,
    required this.initialPassword,
    required this.forceLogin,
  });

  @override
  State<_AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<_AuthDialog> {
  AuthTab tab = AuthTab.login;

  // 动态邮箱 UI
  final emailPrefixCtrl = TextEditingController();
  final emailFullCtrl = TextEditingController();
  String selectedSuffix = '';

  final pwdCtrl = TextEditingController();

  final inviteCtrl = TextEditingController();
  final emailCodeCtrl = TextEditingController();

  EmailCodeScene codeScene = EmailCodeScene.register;

  bool loading = false;
  String? errText;

  bool configOk = false;
  GuestConfig? guestConfig;

  @override
  void initState() {
    super.initState();
    emailFullCtrl.text = widget.initialEmail.trim();
    pwdCtrl.text = widget.initialPassword;

    WidgetsBinding.instance.addPostFrameCallback((_) => _loadGuestConfig());
  }

  @override
  void dispose() {
    emailPrefixCtrl.dispose();
    emailFullCtrl.dispose();
    pwdCtrl.dispose();
    inviteCtrl.dispose();
    emailCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadGuestConfig() async {
    setState(() {
      loading = true;
      errText = null;
      configOk = false;
      guestConfig = null;
    });

    try {
      final resp = await http
          .get(_apiV1('/guest/comm/config'), headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 12));

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw Exception('config 不通：HTTP ${resp.statusCode}');
      }

      final j = jsonDecode(resp.body);
      final cfg = GuestConfig.fromJson(j);
      if (cfg == null) throw Exception('config 返回格式异常');

      // 若启用邮箱后缀白名单：自动拆分邮箱
      if (cfg.isEmailVerify == 1 && cfg.emailSuffixes.isNotEmpty) {
        final full = emailFullCtrl.text.trim();
        if (full.contains('@')) {
          final parts = full.split('@');
          emailPrefixCtrl.text = parts.first;
          final suf = parts.length > 1 ? parts.last : '';
          selectedSuffix = cfg.emailSuffixes.contains(suf) ? suf : cfg.emailSuffixes.first;
        } else {
          emailPrefixCtrl.text = full;
          selectedSuffix = cfg.emailSuffixes.first;
        }
      }

      setState(() {
        guestConfig = cfg;
        configOk = true;
      });
    } catch (e) {
      setState(() {
        errText = '联通检测失败：$e\n（此接口无需认证，不通说明网站/API 有问题）';
        configOk = false;
      });
    } finally {
      setState(() => loading = false);
    }
  }

  String _currentEmail() {
    final cfg = guestConfig;
    if (cfg != null && cfg.isEmailVerify == 1 && cfg.emailSuffixes.isNotEmpty) {
      final prefix = emailPrefixCtrl.text.trim();
      final suffix = selectedSuffix.trim();
      if (prefix.isEmpty || suffix.isEmpty) return '';
      return '$prefix@$suffix';
    }
    return emailFullCtrl.text.trim();
  }

  Future<Map<String, dynamic>> _postJson(String pathUnderApiV1, Map<String, dynamic> body) async {
    final resp = await http
        .post(
          _apiV1(pathUnderApiV1),
          headers: const {'Accept': 'application/json', 'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 20));

    Map<String, dynamic> j;
    try {
      final parsed = jsonDecode(resp.body);
      if (parsed is Map<String, dynamic>) {
        j = parsed;
      } else {
        throw Exception('Unexpected JSON type');
      }
    } catch (_) {
      throw Exception('后端返回不是 JSON：HTTP ${resp.statusCode}\n${resp.body}');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final msg = j['message']?.toString() ?? 'HTTP ${resp.statusCode}';
      final errs = j['errors']?.toString() ?? '';
      throw Exception(errs.isEmpty ? msg : '$msg\n$errs');
    }
    return j;
  }

  Future<void> _sendEmailCode() async {
    setState(() {
      loading = true;
      errText = null;
    });
    try {
      if (!configOk) throw Exception('config 未联通，无法继续');
      final email = _currentEmail();
      if (email.isEmpty) throw Exception('请输入邮箱');

      await _postJson('/passport/auth/sendEmailCode', {
        'email': email,
        'scene': codeScene.value,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('验证码已发送（场景：${codeScene.label}）')),
      );
    } catch (e) {
      setState(() => errText = '错误：$e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _login() async {
    setState(() {
      loading = true;
      errText = null;
    });
    try {
      if (!configOk) throw Exception('config 未联通，无法继续');

      final email = _currentEmail();
      final pwd = pwdCtrl.text;
      if (email.isEmpty || pwd.isEmpty) throw Exception('请输入邮箱和密码');

      final resp = await http
          .post(
            _apiV1('/passport/auth/login'),
            headers: const {'Accept': 'application/json', 'Content-Type': 'application/json'},
            body: jsonEncode({'email': email, 'password': pwd}),
          )
          .timeout(const Duration(seconds: 20));

      Map<String, dynamic> j;
      try {
        final parsed = jsonDecode(resp.body);
        if (parsed is Map<String, dynamic>) {
          j = parsed;
        } else {
          throw Exception('Unexpected JSON type');
        }
      } catch (_) {
        throw Exception('后端返回不是 JSON：HTTP ${resp.statusCode}\n${resp.body}');
      }

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final msg = j['message']?.toString() ?? 'HTTP ${resp.statusCode}';
        final errs = j['errors']?.toString() ?? '';
        throw Exception(errs.isEmpty ? msg : '$msg\n$errs');
      }

      final authData = _extractAuthData(j);
      if (authData.isEmpty) throw Exception('登录成功但未找到 data.auth_data');

      final cookie = _extractSessionCookie(resp.headers['set-cookie']);

      if (!mounted) return;
      Navigator.of(context).pop(
        AuthDialogResult(email: email, password: pwd, authData: authData, cookie: cookie),
      );
    } catch (e) {
      setState(() => errText = '错误：$e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _register() async {
    setState(() {
      loading = true;
      errText = null;
    });
    try {
      if (!configOk) throw Exception('config 未联通，无法继续');

      final email = _currentEmail();
      final pwd = pwdCtrl.text;
      if (email.isEmpty || pwd.isEmpty) throw Exception('请输入邮箱和密码');

      final invite = inviteCtrl.text.trim();

      await _postJson('/passport/auth/register', {
        'email': email,
        'password': pwd,
        if (invite.isNotEmpty) 'invite_code': invite,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('注册成功，正在登录…')));
      await _login();
    } catch (e) {
      setState(() => errText = '错误：$e');
      setState(() => loading = false);
    }
  }

  Future<void> _resetPassword() async {
    setState(() {
      loading = true;
      errText = null;
    });
    try {
      if (!configOk) throw Exception('config 未联通，无法继续');

      final email = _currentEmail();
      final pwd = pwdCtrl.text;
      final code = emailCodeCtrl.text.trim();
      if (email.isEmpty) throw Exception('请输入邮箱');
      if (pwd.isEmpty) throw Exception('请输入新密码');
      if (code.isEmpty) throw Exception('请输入邮箱验证码');

      await _postJson('/passport/auth/resetPassword', {
        'email': email,
        'password': pwd,
        'email_code': code,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('重置成功，正在登录…')));
      await _login();
    } catch (e) {
      setState(() => errText = '错误：$e');
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = guestConfig;
    final useSuffixUi = (cfg != null && cfg.isEmailVerify == 1 && cfg.emailSuffixes.isNotEmpty);

    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(switch (tab) { AuthTab.login => '登录', AuthTab.register => '注册', AuthTab.forgot => '忘记密码' })),
          IconButton(
            tooltip: '重新检测联通',
            onPressed: loading ? null : _loadGuestConfig,
            icon: Icon(configOk ? Icons.verified : Icons.error_outline, color: configOk ? Colors.green : Colors.red),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 只展示，不可编辑
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '网站：${AppConfig.siteBaseUrl}\nAPI：${AppConfig.apiBaseUrl}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
              const SizedBox(height: 10),

              SegmentedButton<AuthTab>(
                segments: const [
                  ButtonSegment(value: AuthTab.login, label: Text('登录')),
                  ButtonSegment(value: AuthTab.register, label: Text('注册')),
                  ButtonSegment(value: AuthTab.forgot, label: Text('忘记密码')),
                ],
                selected: {tab},
                onSelectionChanged: loading
                    ? null
                    : (s) {
                        setState(() {
                          tab = s.first;
                          errText = null;
                          codeScene = (tab == AuthTab.forgot) ? EmailCodeScene.resetPassword : EmailCodeScene.register;
                        });
                      },
              ),
              const SizedBox(height: 12),

              // 动态邮箱输入
              if (useSuffixUi) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: emailPrefixCtrl,
                        decoration: const InputDecoration(labelText: '邮箱前缀'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: (selectedSuffix.isNotEmpty) ? selectedSuffix : cfg!.emailSuffixes.first,
                        items: cfg!.emailSuffixes.map((s) => DropdownMenuItem(value: s, child: Text('@$s'))).toList(),
                        onChanged: loading ? null : (v) => setState(() => selectedSuffix = v ?? selectedSuffix),
                        decoration: const InputDecoration(labelText: '邮箱后缀'),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                TextField(
                  controller: emailFullCtrl,
                  decoration: const InputDecoration(labelText: '邮箱'),
                  keyboardType: TextInputType.emailAddress,
                ),
              ],

              const SizedBox(height: 10),

              TextField(
                controller: pwdCtrl,
                decoration: InputDecoration(labelText: tab == AuthTab.forgot ? '新密码' : '密码'),
                obscureText: true,
              ),

              if (tab == AuthTab.register) ...[
                const SizedBox(height: 10),
                TextField(controller: inviteCtrl, decoration: const InputDecoration(labelText: '邀请码（可选）')),
              ],

              if (tab == AuthTab.forgot) ...[
                const SizedBox(height: 10),
                TextField(controller: emailCodeCtrl, decoration: const InputDecoration(labelText: '邮箱验证码')),
              ],

              if (tab != AuthTab.login) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<EmailCodeScene>(
                        value: codeScene,
                        items: const [
                          DropdownMenuItem(value: EmailCodeScene.register, child: Text('验证码场景：注册')),
                          DropdownMenuItem(value: EmailCodeScene.resetPassword, child: Text('验证码场景：重置密码')),
                        ],
                        onChanged: loading ? null : (v) => setState(() => codeScene = v ?? codeScene),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: (!configOk || loading) ? null : _sendEmailCode,
                      child: Text(loading ? '发送中…' : '发送验证码'),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  configOk ? '✅ config 联通正常（无需认证）' : '❌ config 不通：网站/API 可能有问题',
                  style: TextStyle(color: configOk ? Colors.green : Colors.red),
                ),
              ),

              if (cfg != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'is_email_verify=${cfg.isEmailVerify}  suffixes=${cfg.emailSuffixes.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
              ],

              if (errText != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.red.shade200),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(errText!, style: const TextStyle(color: Colors.red)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (!widget.forceLogin)
          TextButton(onPressed: loading ? null : () => Navigator.of(context).pop(null), child: const Text('关闭')),
        if (tab == AuthTab.login)
          ElevatedButton(onPressed: (!configOk || loading) ? null : _login, child: Text(loading ? '处理中…' : '登录')),
        if (tab == AuthTab.register)
          ElevatedButton(onPressed: (!configOk || loading) ? null : _register, child: Text(loading ? '处理中…' : '注册并登录')),
        if (tab == AuthTab.forgot)
          ElevatedButton(onPressed: (!configOk || loading) ? null : _resetPassword, child: Text(loading ? '处理中…' : '重置并登录')),
      ],
    );
  }
}
