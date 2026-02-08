import 'dart:convert';
import 'package:flutter/material.dart';

import 'app_storage.dart';
import 'auth_page.dart';
import 'session_service.dart';
import 'xboard_api.dart';

class HomePage extends StatefulWidget {
  final Map<String, dynamic>? initialSubscribeCache;
  const HomePage({super.key, this.initialSubscribeCache});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool loading = false;
  String? err;
  Map<String, dynamic>? data;

  @override
  void initState() {
    super.initState();
    data = widget.initialSubscribeCache ?? AppStorage.I.getJson(AppStorage.kSubscribeCache);
    // 后台刷新最新（不阻塞首屏）
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      loading = true;
      err = null;
    });

    try {
      final sub = await XBoardApi.I.getSubscribe();
      final d = (sub['data'] is Map) ? Map<String, dynamic>.from(sub['data']) : <String, dynamic>{};
      await AppStorage.I.setJson(AppStorage.kSubscribeCache, d);
      setState(() => data = d);
    } catch (e) {
      // 常见：403/过期
      final es = e.toString();
      if (es.contains('403') || es.contains('未登录') || es.contains('过期')) {
        await SessionService.I.clearSessionOnly();
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AuthPage(force: true)));
        return;
      }
      setState(() => err = e.toString());
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _logout() async {
    await SessionService.I.logoutClearAll();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const AuthPage(force: true)));
  }

  @override
  Widget build(BuildContext context) {
    final subUrl = (data?['subscribe_url'] ?? '').toString();

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F17),
        title: const Text('订阅'),
        actions: [
          IconButton(onPressed: loading ? null : _refresh, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: loading ? null : _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: const Color(0xFF121827),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('订阅链接', style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    SelectableText(subUrl.isEmpty ? '暂无（正在刷新或未订阅）' : subUrl),
                    if (loading) ...[
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
                color: const Color(0xFF121827),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ').convert(data ?? {}),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
              ),
            ),
            if (err != null) ...[
              const SizedBox(height: 10),
              Text(err!, style: const TextStyle(color: Colors.redAccent)),
            ],
          ],
        ),
      ),
    );
  }
}
