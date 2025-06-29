// ★★★ ファイル全体をこの内容に完全に置き換えてください ★★★

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

// 1. Mockito ライブラリを使って、プラットフォームとアプリ本体の偽物（モック）を定義します。
//    これが `implements` の問題を回避する、公式に推奨された方法です。
class MockFirebasePlatform extends Mock
    with MockPlatformInterfaceMixin
    implements FirebasePlatform {}

class MockFirebaseApp extends Mock implements FirebaseApp {}

// 2. テストのセットアップ時に呼ばれる、ただ一つの正しいセットアップ関数を定義します。
void setupFirebaseMocks() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 偽物のプラットフォームとアプリのインスタンスを作成します。
  final mockPlatform = MockFirebasePlatform();
  final mockApp = MockFirebaseApp();

  // `FirebasePlatform.instance` に、私たちの作った偽のプラットフォームをセットします。
  // これにより、テスト中は本物のFirebaseの代わりにこの偽物が使われます。
  FirebasePlatform.instance = mockPlatform;

  // `Firebase.initializeApp()` が呼ばれたときに、偽のアプリを返すように設定します。
  // `anyNamed` を使うことで、どんな引数で呼ばれても対応できます。
  when(mockPlatform.initializeApp(
    name: anyNamed('name'),
    options: anyNamed('options'),
  )).thenAnswer((_) => Future.value(mockApp));

  // `Firebase.app()` が呼ばれたときも、偽のアプリを返すように設定します。
  when(mockPlatform.app(any)).thenReturn(mockApp);
}