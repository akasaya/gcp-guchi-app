//import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
//import 'package:mockito/mockito.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:mocktail/mocktail.dart';   

// このセットアップ関数を、Firebaseを利用するテストの`main`関数の冒頭で呼び出してください。
void setupFirebaseMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // FirebasePlatformのインスタンスを、これから定義するモックに差し替えます。
  FirebasePlatform.instance = MockFirebasePlatform();
}

// FirebasePlatformのモック。
// MockPlatformInterfaceMixinを使うのが、ルール違反を回避するための公式な方法です。
class MockFirebasePlatform extends Mock
    with MockPlatformInterfaceMixin
    implements FirebasePlatform {
  // Firebase.initializeApp()が呼ばれた際の挙動を定義します。
  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    // モックのFirebaseAppPlatformインスタンスを返します。
    return MockFirebaseAppPlatform();
  }

  // Firebase.app()が呼ばれた際の挙動を定義します。
  // これが未定義だったため `UnimplementedError: app() has not been implemented` が発生していました。
  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) {
    return MockFirebaseAppPlatform();
  }
}

// FirebaseAppPlatformのモック
class MockFirebaseAppPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements FirebaseAppPlatform {
  // テストで必要になる可能性のあるプロパティをモックします。
  @override
  String get name => 'default';

  @override
  FirebaseOptions get options => const FirebaseOptions(
        apiKey: 'fake-api-key',
        appId: 'fake-app-id',
        messagingSenderId: 'fake-sender-id',
        projectId: 'fake-project-id',
      );
}