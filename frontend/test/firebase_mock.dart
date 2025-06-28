import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// --- Core Mocks (for Firebase.initializeApp) ---

// このセットアップ関数は、テスト実行時にFirebaseのネイティブ初期化をバイパスするために必要です。
Future<void> setupFirebaseCoreMocks() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  FirebasePlatform.instance = FakeFirebasePlatform();
}

class FakeFirebasePlatform extends Fake with MockPlatformInterfaceMixin implements FirebasePlatform {
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

class FakeFirebaseAppPlatform extends Fake with MockPlatformInterfaceMixin implements FirebaseAppPlatform {
  @override
  final String name;
  @override
  final FirebaseOptions options;
  FakeFirebaseAppPlatform({required this.name, required this.options});
}


// --- Auth Mocks (for FirebaseAuth, User) ---
// これらが、これまで欠けていたMockクラスです。

class MockUser extends Mock implements User {}

class MockFirebaseAuth extends Mock implements FirebaseAuth {
  final User? _user;

  MockFirebaseAuth({User? signedInUser}) : _user = signedInUser;

  @override
  User? get currentUser => _user;

  @override
  Stream<User?> authStateChanges() {
    return Stream.value(_user);
  }
}