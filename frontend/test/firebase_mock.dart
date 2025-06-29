import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void setupFirebaseMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = FakeFirebasePlatform();
}

class FakeFirebasePlatform extends Fake implements FirebasePlatform {
  // ★★★ 追加: アプリのインスタンスを保持するマップ
  final Map<String, FirebaseAppPlatform> _apps = {};

  // ★★★ 追加: アプリのリストを返すゲッター
  @override
  List<FirebaseAppPlatform> get apps => _apps.values.toList();

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    final appName = name ?? '[DEFAULT]';
    final app = FakeFirebaseAppPlatform(
      name: appName,
      options: options ??
          const FirebaseOptions(
            apiKey: 'fake',
            appId: 'fake',
            messagingSenderId: 'fake',
            projectId: 'fake',
          ),
    );
    // ★★★ 追加: 初期化したアプリをマップに保存
    _apps[appName] = app;
    return app;
  }

  @override
  FirebaseAppPlatform app([String name = '[DEFAULT]']) {
    // ★★★ 修正: マップからアプリを返すように変更
    if (_apps.containsKey(name)) {
      return _apps[name]!;
    }
    // もしアプリがなければ例外をスローする（実際のFirebaseの挙動に合わせる）
    throw Exception('FirebaseApp with name $name has not been initialized');
  }
}

class FakeFirebaseAppPlatform extends Fake implements FirebaseAppPlatform {
  @override
  final String name;
  @override
  final FirebaseOptions options;
  FakeFirebaseAppPlatform({required this.name, required this.options});
}