import 'package:flutter/material.dart';
import 'app_storage.dart';
import 'boot_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStorage.I.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'King',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF7A5CFF),
      ),
      home: const BootPage(),
    );
  }
}
