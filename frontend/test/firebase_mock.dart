// ★★★ ファイル全体をこの内容に完全に置き換えてください ★★★

import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package.plugin_platform_interface/plugin_platform_interface.dart';

// 1. プラットフォーム層が要求する `FirebasePlatform` と `FirebaseAppPlatform` の
//    両方の偽物（モック）を定義します。これがエラーを解決する鍵です。
class MockFirebasePlatform extends Mock
    with MockPlatformInterfaceMixin
    implements FirebasePlatform {}

class MockFirebaseAppPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements FirebaseAppPlatform {
  // `name` と `options` はテスト中にアクセスされる可能性があるため、
  // ダミーの値を返すように設定しておきます。
  @override
  String get name => 'default';
  @override
  FirebaseOptions get options => const FirebaseOptions(
        apiKey: 'fake',
        appId: 'fake',
        messagingSenderId: 'fake',
        projectId: 'fake',
      );
}

// 2. 正しいセットアップ関数を定義します。
void setupFirebaseMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 偽物のプラットフォームと、そのプラットフォームが返す偽物のアプリを作成します。
  final mockPlatform = MockFirebasePlatform();
  final mockApp = MockFirebaseAppPlatform();

  // テスト中は、本物のFirebasePlatformの代わりに、この偽物が使われるように設定します。
  FirebasePlatform.instance = mockPlatform;

  // `Firebase.initializeApp()` が呼ばれたら、偽物のアプリ(`MockFirebaseAppPlatform`)を
  // 返すように設定します。これで型が一致し、エラーが解消されます。
  when(mockPlatform.initializeApp(
    name: anyNamed('name'),
    options: anyNamed('options'),
  )).thenAnswer((_) => Future.value(mockApp));

  // `Firebase.app()`が呼ばれたときも同様に、偽物のアプリを返します。
  when(mockPlatform.app(any)).thenReturn(mockApp);
  
  // `Firebase.apps`が呼ばれたときのために、偽のアプリのリストを返します。
  when(mockPlatform.apps).thenReturn([mockApp]);
}