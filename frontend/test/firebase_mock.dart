import 'package:firebase_auth/firebase_auth.dart';
//import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
//import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// --- Core Mocks (for Firebase.initializeApp) ---

// このセットアップ関数は、テスト実行時にFirebaseのネイティブ初期化をバイパスするために必要です。
void setupFirebaseMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Firebase.initializeApp() の呼び出しをモックする
  FirebasePlatform.instance = FakeFirebasePlatform();
}


class FakeFirebasePlatform extends Mock with MockPlatformInterfaceMixin implements FirebasePlatform { // ★★★ FakeをMockに変更 ★★★
  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    return FakeFirebaseAppPlatform(
      name: name ?? '[DEFAULT]',
      options: options ?? const FirebaseOptions(
        apiKey: 'fake',
        appId: 'fake',
        messagingSenderId: 'fake',
        projectId: 'fake',
      ),
    );
  }
}

class FakeFirebaseAppPlatform extends Mock with MockPlatformInterfaceMixin implements FirebaseAppPlatform { // ★★★ FakeをMockに変更 ★★★
  @override
  final String name;
  @override
  final FirebaseOptions options;
  FakeFirebaseAppPlatform({required this.name, required this.options});
}
