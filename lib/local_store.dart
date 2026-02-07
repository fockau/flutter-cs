import 'package:shared_preferences/shared_preferences.dart';

class LocalStore {
  static final LocalStore I = LocalStore._();
  LocalStore._();

  late SharedPreferences _sp;

  Future<void> init() async {
    _sp = await SharedPreferences.getInstance();
  }

  String get email => _sp.getString('email') ?? '';
  String get password => _sp.getString('password') ?? '';
  String get authData => _sp.getString('authData') ?? '';
  String get cookie => _sp.getString('cookie') ?? '';

  Future<void> saveAuth({
    required String email,
    required String password,
    required String authData,
    required String cookie,
  }) async {
    await _sp.setString('email', email);
    await _sp.setString('password', password);
    await _sp.setString('authData', authData);
    await _sp.setString('cookie', cookie);
  }

  Future<void> clearAuth() async {
    await _sp.remove('authData');
    await _sp.remove('cookie');
  }

  Future<void> clearAll() async {
    await _sp.clear();
  }
}
