import 'app_storage.dart';

class SessionService {
  static final SessionService I = SessionService._();
  SessionService._();

  String get authData => AppStorage.I.getString(AppStorage.kAuthData);
  String get cookie => AppStorage.I.getString(AppStorage.kCookie);
  bool get isLoggedIn => authData.trim().isNotEmpty;

  String get email => AppStorage.I.getString(AppStorage.kEmail);
  String get password => AppStorage.I.getString(AppStorage.kPassword);
  bool get rememberPassword => AppStorage.I.getBool(AppStorage.kRememberPassword, def: true);

  Future<void> saveLogin({
    required String email,
    required String password,
    required String authData,
    required String cookie,
    required bool rememberPassword,
  }) async {
    await AppStorage.I.setString(AppStorage.kEmail, email);
    await AppStorage.I.setBool(AppStorage.kRememberPassword, rememberPassword);

    if (rememberPassword) {
      await AppStorage.I.setString(AppStorage.kPassword, password);
    } else {
      await AppStorage.I.remove(AppStorage.kPassword);
    }

    await AppStorage.I.setString(AppStorage.kAuthData, authData);
    await AppStorage.I.setString(AppStorage.kCookie, cookie);
  }

  Future<void> clearSessionOnly() async {
    await AppStorage.I.remove(AppStorage.kAuthData);
    await AppStorage.I.remove(AppStorage.kCookie);
  }
}
