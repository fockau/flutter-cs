import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_storage.dart';
import 'home_page.dart';
import 'xboard_api.dart';

enum AuthTab { login, register, reset }

class AuthPage extends StatefulWidget {
  final bool force; // force=true：未登录不可返回/不可关闭
  const AuthPage({super.key, required this.force});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  AuthTab tab = AuthTab.login;

  GuestConfigParsed guest = const GuestConfigParsed(isEmailVerify: 0, emailWhitelistSuffix: []);
  bool loadingGuest = true;

  bool busy = false;
  String? err;

  // login
  final _loginKey = GlobalKey<FormState>();
  final loginEmailCtrl = TextEditingController();
  final loginPwdCtrl = TextEditingController();
  bool rememberPwd = true;

  // register
  final _regKey = GlobalKey<FormState>();
  final regEmailPrefixCtrl = TextEditingController();
  String? regEmailSuffix;
  final regEmailPlainCtrl = TextEditingController();
  final regPwd1Ctrl = TextEditingController();
  final regPwd2Ctrl = TextEditingController();
  final regInviteCtrl = TextEditingController();
  final regEmailCodeCtrl = TextEditingController();
  bool regPwdTouched = false;

  // reset
  final _resetKey = GlobalKey<FormState>();
  final resetEmailPrefixCtrl = TextEditingController();
  String? resetEmailSuffix;
  final resetEmailPlainCtrl = TextEditingController();
  final resetCodeCtrl = TextEditingController();
  final resetPwd1Ctrl = TextEditingController();
  final resetPwd2Ctrl = TextEditingController();
  bool resetPwdTouched = false;

  bool get hasWhitelist => guest.emailWhitelistSuffix.isNotEmpty;

  @override
  void initState() {
    super.initState();

    // 预填登录信息
    loginEmailCtrl.text = XBoardApi.I.email;
    rememberPwd = XBoardApi.I.rememberPassword;
    if (rememberPwd) loginPwdCtrl.text = XBoardApi.I.password;

    // 先把 guest config 从缓存读出来（UI 秒出）
    final cached = AppStorage.I.getJson(AppStorage.kGuestConfigCache);
    if (cached != null) {
      final isEv = (cached['is_email_verify'] is num) ? (cached['is_email_verify'] as num).toInt() : 0;
      final wl = (cached['email_whitelist_suffix'] is List)
          ? (cached['email_whitelist_suffix'] as List).map((e) => e.toString()).toList()
          : <String>[];
      guest = GuestConfigParsed(isEmailVerify: isEv, emailWhitelistSuffix: wl);
      if (guest.emailWhitelistSuffix.isNotEmpty) {
        regEmailSuffix ??= guest.emailWhitelistSuffix.first;
        resetEmailSuffix ??= guest.emailWhitelistSuffix.first;
      }
    }

    _reloadAll();
  }

  @override
  void dispose() {
    loginEmailCtrl.dispose();
    loginPwdCtrl.dispose();

    regEmailPrefixCtrl.dispose();
    regEmailPlainCtrl.dispose();
    regPwd1Ctrl.dispose();
    regPwd2Ctrl.dispose();
    regInviteCtrl.dispose();
    regEmailCodeCtrl.dispose();

    resetEmailPrefixCtrl.dispose();
    resetEmailPlainCtrl.dispose();
    resetCodeCtrl.dispose();
    resetPwd1Ctrl.dispose();
    resetPwd2Ctrl.dispose();

    super.dispose();
  }

  Future<void> _openExternal(String url) async {
    final u = url.trim();
    if (u.isEmpty) return;
    final uri = Uri.tryParse(u);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _reloadAll() async {
    setState(() {
      loadingGuest = true;
      err = null;
    });

    try {
      await XBoardApi.I.refreshDomainRacer(); // 重新竞速（刷新按钮也会走这条）
      final g = await XBoardApi.I.fetchGuestConfig();
      guest = g;
      await AppStorage.I.setJson(AppStorage.kGuestConfigCache, g.toJson());

      if (guest.emailWhitelistSuffix.isNotEmpty) {
        regEmailSuffix ??= guest.emailWhitelistSuffix.first;
        resetEmailSuffix ??= guest.emailWhitelistSuffix.first;
      }
    } catch (e) {
      // guest 拉不到，不阻塞登录，但会影响注册/找回的动态显示
      err = '联通检测失败：${e.toString()}';
    } finally {
      if (mounted) {
        setState(() => loadingGuest = false);
      }
    }
  }

  // ---------- helpers ----------
  String _buildEmail({
    required TextEditingController plain,
    required TextEditingController prefix,
    required String? suffix,
  }) {
    if (!hasWhitelist) return plain.text.trim();
    final p = prefix.text.trim();
    final s = (suffix ?? '').trim();
    if (p.isEmpty || s.isEmpty) return '';
    return '$p@$s';
  }

  String? _vEmailPlain(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '请输入邮箱';
    if (!s.contains('@')) return '邮箱格式不正确';
    return null;
  }

  String? _vEmailPrefix(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty) return '请输入邮箱前缀';
    if (s.contains('@')) return '这里不需要 @';
    return null;
  }

  String? _vPwdMin8(String? v) {
    final s = (v ?? '');
    if (s.isEmpty) return '请输入密码';
    if (s.length < 8) return '密码至少 8 位';
    return null;
  }

  String? _vPwd2Match(String? v, TextEditingController pwd1) {
    final s = (v ?? '');
    if (s.isEmpty) return '请再次输入密码';
    if (s.length < 8) return '密码至少 8 位';
    if (s != pwd1.text) return '两次密码不一致';
    return null;
  }

  Widget _emailField({
    required String label,
    required TextEditingController plainCtrl,
    required TextEditingController prefixCtrl,
    required String? suffixValue,
    required ValueChanged<String?> onSuffixChanged,
    required bool enabled,
  }) {
    if (!hasWhitelist) {
      return TextFormField(
        controller: plainCtrl,
        enabled: enabled,
        keyboardType: TextInputType.emailAddress,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        validator: _vEmailPlain,
      );
    }

    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: prefixCtrl,
            enabled: enabled,
            decoration: const InputDecoration(labelText: '邮箱前缀', border: OutlineInputBorder()),
            validator: _vEmailPrefix,
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 140,
          child: DropdownButtonFormField<String>(
            value: suffixValue ?? (guest.emailWhitelistSuffix.isNotEmpty ? guest.emailWhitelistSuffix.first : null),
            items: guest.emailWhitelistSuffix
                .map((e) => DropdownMenuItem<String>(value: e, child: Text('@$e', overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: enabled ? onSuffixChanged : null,
            decoration: const InputDecoration(labelText: '后缀', border: OutlineInputBorder()),
          ),
        ),
      ],
    );
  }

  // ---------- actions ----------
  Future<void> _doLogin() async {
    setState(() {
      busy = true;
      err = null;
    });

    try {
      if (!_loginKey.currentState!.validate()) return;

      final j = await XBoardApi.I.login(
        email: loginEmailCtrl.text.trim(),
        password: loginPwdCtrl.text,
      );

      // 保存登录（不自动带 cookie，Authorization 足够）
      await XBoardApi.I.saveLoginFromResponse(
        loginEmailCtrl.text.trim(),
        loginPwdCtrl.text,
        j,
        rememberPwd,
      );

      // 拉订阅 + 缓存
      final sub = await XBoardApi.I.getSubscribe();
      final subData = (sub['data'] is Map) ? Map<String, dynamic>.from(sub['data']) : <String, dynamic>{};
      await AppStorage.I.setJson(AppStorage.kSubscribeCache, subData);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => HomePage(initialSubscribeCache: subData)),
      );
    } catch (e) {
      setState(() => err = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _sendCodeForRegister() async {
    setState(() {
      busy = true;
      err = null;
    });
    try {
      if (!_regKey.currentState!.validate()) return;
      final email = _buildEmail(plain: regEmailPlainCtrl, prefix: regEmailPrefixCtrl, suffix: regEmailSuffix);
      if (email.isEmpty) throw Exception('邮箱不完整');

      await XBoardApi.I.sendEmailCode(email: email, scene: 'register');
      setState(() => err = '验证码已发送，请查收邮箱');
    } catch (e) {
      setState(() => err = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _doRegister() async {
    setState(() {
      busy = true;
      err = null;
    });

    try {
      if (!_regKey.currentState!.validate()) return;

      final email = _buildEmail(plain: regEmailPlainCtrl, prefix: regEmailPrefixCtrl, suffix: regEmailSuffix);
      if (email.isEmpty) throw Exception('邮箱不完整');

      final emailCode = (guest.isEmailVerify == 1) ? regEmailCodeCtrl.text.trim() : null;

      await XBoardApi.I.register(
        email: email,
        password: regPwd1Ctrl.text,
        inviteCode: regInviteCtrl.text.trim().isEmpty ? null : regInviteCtrl.text.trim(),
        emailCode: emailCode,
      );

      // 注册成功：不自动登录，回登录
      setState(() {
        tab = AuthTab.login;
        err = '注册成功，请登录';
        loginEmailCtrl.text = email;
      });
    } catch (e) {
      setState(() => err = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _sendCodeForReset() async {
    setState(() {
      busy = true;
      err = null;
    });
    try {
      if (!_resetKey.currentState!.validate()) return;
      final email = _buildEmail(plain: resetEmailPlainCtrl, prefix: resetEmailPrefixCtrl, suffix: resetEmailSuffix);
      if (email.isEmpty) throw Exception('邮箱不完整');

      await XBoardApi.I.sendEmailCode(email: email, scene: 'reset_password');
      setState(() => err = '验证码已发送，请查收邮箱');
    } catch (e) {
      setState(() => err = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _doReset() async {
    setState(() {
      busy = true;
      err = null;
    });

    try {
      if (!_resetKey.currentState!.validate()) return;

      final email = _buildEmail(plain: resetEmailPlainCtrl, prefix: resetEmailPrefixCtrl, suffix: resetEmailSuffix);
      if (email.isEmpty) throw Exception('邮箱不完整');

      if (guest.isEmailVerify != 1) {
        throw Exception('当前站点未开启邮箱验证，请联系管理员重置密码。');
      }

      final code = resetCodeCtrl.text.trim();
      if (code.isEmpty) throw Exception('请输入验证码');

      await XBoardApi.I.resetPassword(
        email: email,
        password: resetPwd1Ctrl.text,
        emailCode: code,
      );

      setState(() {
        tab = AuthTab.login;
        err = '密码重置成功，请登录';
        loginEmailCtrl.text = email;
      });
    } catch (e) {
      setState(() => err = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final title = switch (tab) {
      AuthTab.login => '登录',
      AuthTab.register => '注册帐号',
      AuthTab.reset => '找回密码',
    };

    return PopScope(
      canPop: !widget.force,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F17),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                        const Spacer(),

                        IconButton(
                          tooltip: '刷新',
                          onPressed: busy ? null : _reloadAll,
                          icon: const Icon(Icons.refresh),
                        ),
                        const SizedBox(width: 6),

                        TextButton(
                          onPressed: () => _openExternal(XBoardApi.I.supportUrl),
                          child: const Text('客服'),
                        ),
                        const SizedBox(width: 6),

                        TextButton(
                          onPressed: () => _openExternal(XBoardApi.I.websiteUrl),
                          child: const Text('官网'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    Card(
                      color: const Color(0xFF121827),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: switch (tab) {
                            AuthTab.login => _buildLogin(),
                            AuthTab.register => _buildRegister(),
                            AuthTab.reset => _buildReset(),
                          },
                        ),
                      ),
                    ),

                    if (err != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: (err!.contains('成功') || err!.contains('已发送') ? Colors.green : Colors.red)
                              .withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: (err!.contains('成功') || err!.contains('已发送') ? Colors.green : Colors.red)
                                .withOpacity(0.3),
                          ),
                        ),
                        child: Text(
                          err!,
                          style: TextStyle(
                            color: err!.contains('成功') || err!.contains('已发送')
                                ? Colors.greenAccent
                                : Colors.redAccent,
                          ),
                        ),
                      ),
                    ],

                    const Spacer(),

                    if (widget.force)
                      Text(
                        '需要登录后才能继续',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withOpacity(0.55)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLogin() {
    return Form(
      key: _loginKey,
      child: Column(
        key: const ValueKey('login'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: loginEmailCtrl,
            enabled: !busy,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: '邮箱', border: OutlineInputBorder()),
            validator: _vEmailPlain,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: loginPwdCtrl,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
            validator: _vPwdMin8,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Checkbox(
                value: rememberPwd,
                onChanged: busy ? null : (v) => setState(() => rememberPwd = v ?? true),
              ),
              const Text('记住密码'),
              const Spacer(),
              if (loadingGuest) Text('检测中…', style: TextStyle(color: Colors.white.withOpacity(0.6))),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: busy ? null : _doLogin,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('登录'),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              TextButton(
                onPressed: busy ? null : () => setState(() => tab = AuthTab.reset),
                child: Text('忘记密码？', style: TextStyle(color: Colors.white.withOpacity(0.75))),
              ),
              const Spacer(),
              TextButton(
                onPressed: busy ? null : () => setState(() => tab = AuthTab.register),
                child: Text('没有账号？去注册', style: TextStyle(color: Colors.white.withOpacity(0.75))),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRegister() {
    return Form(
      key: _regKey,
      child: Column(
        key: const ValueKey('register'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _emailField(
            label: '邮箱',
            plainCtrl: regEmailPlainCtrl,
            prefixCtrl: regEmailPrefixCtrl,
            suffixValue: regEmailSuffix,
            onSuffixChanged: (v) => setState(() => regEmailSuffix = v),
            enabled: !busy,
          ),
          const SizedBox(height: 12),

          if (guest.isEmailVerify == 1) ...[
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: regEmailCodeCtrl,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: '邮箱验证码', border: OutlineInputBorder()),
                    validator: (v) => (v ?? '').trim().isEmpty ? '请输入验证码' : null,
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 120,
                  height: 48,
                  child: OutlinedButton(
                    onPressed: busy ? null : _sendCodeForRegister,
                    child: const Text('发送验证码'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          TextFormField(
            controller: regPwd1Ctrl,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码（至少8位）', border: OutlineInputBorder()),
            onChanged: (_) => setState(() => regPwdTouched = true),
            validator: _vPwdMin8,
          ),
          if (regPwdTouched && regPwd1Ctrl.text.length < 8) ...[
            const SizedBox(height: 6),
            Text('密码至少 8 位', style: TextStyle(color: Colors.redAccent.withOpacity(0.9))),
          ],
          const SizedBox(height: 12),

          TextFormField(
            controller: regPwd2Ctrl,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: '确认密码', border: OutlineInputBorder()),
            validator: (v) => _vPwd2Match(v, regPwd1Ctrl),
          ),
          const SizedBox(height: 12),

          TextFormField(
            controller: regInviteCtrl,
            enabled: !busy,
            decoration: const InputDecoration(labelText: '邀请码（可选）', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),

          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: busy ? null : _doRegister,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('注册'),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy ? null : () => setState(() => tab = AuthTab.login),
              child: Text('返回登录', style: TextStyle(color: Colors.white.withOpacity(0.75))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReset() {
    if (guest.isEmailVerify != 1) {
      return Column(
        key: const ValueKey('reset_disabled'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '当前站点未开启邮箱验证，请联系管理员重置密码。',
            style: TextStyle(color: Colors.white.withOpacity(0.75)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: busy ? null : () => setState(() => tab = AuthTab.login),
              child: const Text('返回登录'),
            ),
          ),
        ],
      );
    }

    return Form(
      key: _resetKey,
      child: Column(
        key: const ValueKey('reset'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _emailField(
            label: '邮箱',
            plainCtrl: resetEmailPlainCtrl,
            prefixCtrl: resetEmailPrefixCtrl,
            suffixValue: resetEmailSuffix,
            onSuffixChanged: (v) => setState(() => resetEmailSuffix = v),
            enabled: !busy,
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: resetCodeCtrl,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: '邮箱验证码', border: OutlineInputBorder()),
                  validator: (v) => (v ?? '').trim().isEmpty ? '请输入验证码' : null,
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 120,
                height: 48,
                child: OutlinedButton(
                  onPressed: busy ? null : _sendCodeForReset,
                  child: const Text('发送验证码'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          TextFormField(
            controller: resetPwd1Ctrl,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: '新密码（至少8位）', border: OutlineInputBorder()),
            onChanged: (_) => setState(() => resetPwdTouched = true),
            validator: _vPwdMin8,
          ),
          if (resetPwdTouched && resetPwd1Ctrl.text.length < 8) ...[
            const SizedBox(height: 6),
            Text('密码至少 8 位', style: TextStyle(color: Colors.redAccent.withOpacity(0.9))),
          ],
          const SizedBox(height: 12),

          TextFormField(
            controller: resetPwd2Ctrl,
            enabled: !busy,
            obscureText: true,
            decoration: const InputDecoration(labelText: '确认新密码', border: OutlineInputBorder()),
            validator: (v) => _vPwd2Match(v, resetPwd1Ctrl),
          ),
          const SizedBox(height: 12),

          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: busy ? null : _doReset,
              child: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('重置密码'),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy ? null : () => setState(() => tab = AuthTab.login),
              child: Text('返回登录', style: TextStyle(color: Colors.white.withOpacity(0.75))),
            ),
          ),
        ],
      ),
    );
  }
}
