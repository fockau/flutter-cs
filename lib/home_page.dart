import 'dart:convert';
import 'package:flutter/material.dart';
import 'app_storage.dart';
import 'auth_page.dart';
import 'xboard_api.dart';

class HomePage extends StatefulWidget {
  final Map<String, dynamic>? initialSubscribeCache;
  const HomePage({super.key, this.initialSubscribeCache});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool busy = false;
  String? err;
  Map<String, dynamic>? sub;
  DateTime? lastUpdate;

  @override
  void initState() {
    super.initState();
    sub = widget.initialSubscribeCache;
    if (sub != null) lastUpdate = DateTime.now();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      busy = true;
      err = null;
    });
    try {
      final j = await XBoardApi.I.getSubscribe();
      final data = (j['data'] is Map) ? Map<String, dynamic>.from(j['data']) : <String, dynamic>{};
      await AppStorage.I.setJson(AppStorage.kSubscribeCache, data);
      setState(() {
        sub = data;
        lastUpdate = DateTime.now();
      });
    } catch (e) {
      setState(() => err = e.toString());
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _logout() async {
    setState(() {
      busy = true;
      err = null;
    });
    try {
      await XBoardApi.I.logout();
    } catch (_) {}
    await XBoardApi.I.clearSessionOnly();

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AuthPage(force: true)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final subscribeUrl = sub?['subscribe_url']?.toString() ?? '-';
    final pretty = const JsonEncoder.withIndent('  ').convert(sub ?? {});

    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅信息'),
        actions: [
          IconButton(onPressed: busy ? null : _refresh, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: busy ? null : _logout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Card(
                color: const Color(0xFF121827),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('订阅链接', style: TextStyle(color: Colors.white.withOpacity(0.85), fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      SelectableText(subscribeUrl, style: const TextStyle(fontSize: 13.5)),
                      const SizedBox(height: 10),
                      Text(
                        '最后更新：${lastUpdate?.toLocal().toString().split('.').first ?? '-'}',
                        style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12.5),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 44,
                        child: ElevatedButton(
                          onPressed: busy ? null : _refresh,
                          child: busy
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('获取最新订阅'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (err != null) ...[
                const SizedBox(height: 12),
                Text(err!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Card(
                  color: const Color(0xFF121827),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: SingleChildScrollView(child: SelectableText(pretty, style: const TextStyle(fontSize: 12.5))),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
