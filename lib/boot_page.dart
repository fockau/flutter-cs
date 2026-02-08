import 'package:flutter/material.dart';
import 'app_storage.dart';
import 'auth_page.dart';
import 'home_page.dart';
import 'xboard_api.dart';

class BootPage extends StatefulWidget {
  const BootPage({super.key});

  @override
  State<BootPage> createState() => _BootPageState();
}

class _BootPageState extends State<BootPage> {
  String status = '初始化中…';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      setState(() => status = '加载本地缓存…');
      await AppStorage.I.init();

      setState(() => status = '选择最快域名…');
      await XBoardApi.I.initResolveDomain();

      if (XBoardApi.I.isLoggedIn) {
        final cached = AppStorage.I.getJson(AppStorage.kSubscribeCache);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => HomePage(initialSubscribeCache: cached)),
        );
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const AuthPage(force: true)),
        );
      }
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthPage(force: true)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F17),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.shield_moon_outlined, size: 56),
                  const SizedBox(height: 12),
                  const Text('XBoard Client', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 16),
                  const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.2)),
                  const SizedBox(height: 12),
                  Text(status, style: TextStyle(color: Colors.white.withOpacity(0.7))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
