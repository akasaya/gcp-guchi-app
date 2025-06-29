//import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
// import 'package:mockito/mockito.dart'; // 不要なため削除

// --- Core Mocks (for Firebase.initializeApp) ---

void setupFirebaseMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = FakeFirebasePlatform();
}

// ★★★ 修正: Mockitoに依存しないシンプルなFakeクラスに戻す
class FakeFirebasePlatform extends Fake implements FirebasePlatform {
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

  // 実際のFirebaseAppインスタンスを返すように見せかける
  @override
  FirebaseAppPlatform app([String name = '[DEFAULT]']) {
    return FakeFirebaseAppPlatform(name: name, options: const FirebaseOptions(
        apiKey: 'fake',
        appId: 'fake',
        messagingSenderId: 'fake',
        projectId: 'fake',
      ),);
  }
}

// ★★★ 修正: Mockitoに依存しないシンプルなFakeクラスに戻す
class FakeFirebaseAppPlatform extends Fake implements FirebaseAppPlatform {
  @override
  final String name;
  @override
  final FirebaseOptions options;
  FakeFirebaseAppPlatform({required this.name, required this.options});
}