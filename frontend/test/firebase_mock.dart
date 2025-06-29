// ★★★ ファイル全体をこの内容に完全に置き換えてください ★★★

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

// このセットアップ関数を、各テストファイルの `main` 関数の最初に呼び出します。
void setupFirebaseMocks() {
  // Flutterのテストで非同期処理を扱うための必須のおまじないです。
  TestWidgetsFlutterBinding.ensureInitialized();

  // `FirebasePlatform.instance` に、これから定義する「偽のプラットフォーム」をセットします。
  // これが、テスト中に本物のFirebaseが動かないようにするための核心部分です。
  FirebasePlatform.instance = FakeFirebasePlatform();
}

// これが、Firebase Platformの正しい偽物の作り方です。
// `implements` ではなく `extends` を使うことで、ルール違反のエラーを回避します。
class FakeFirebasePlatform extends FirebasePlatform {
  // コンストラクタで、必須の引数を持つ親クラスのコンストラクタを呼び出します。
  FakeFirebasePlatform() : super();

  // `initializeApp()` が呼ばれたら、何もしないで、ただ成功したことを示す
  // `Future` を返すように「ふり」をします。
  // これにより、テスト内の `await Firebase.initializeApp()` が正常に完了します。
  @override
  Future<FirebaseApp> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    // 戻り値の型 `FirebaseApp` を満たすための、最小限の偽物クラスを返します。
    return FakeFirebaseApp();
  }
}

// `FirebaseApp` の偽物クラスです。
// テストのセットアップを通過するためだけに存在し、中身は空で問題ありません。
class FakeFirebaseApp implements FirebaseApp {
  @override
  String get name => 'fake_app';

  @override
  FirebaseOptions get options => const FirebaseOptions(
        apiKey: 'fake_api_key',
        appId: 'fake_app_id',
        messagingSenderId: 'fake_sender_id',
        projectId: 'fake_project_id',
      );
  
  // テストで使われないメソッドは、とりあえず例外を投げるようにしておくのが安全です。
  @override
  Future<void> delete() async {}
  @override
  Future<void> setAutomaticDataCollectionEnabled(bool enabled) async {}
  @override
  Future<void> setAutomaticResourceManagementEnabled(bool enabled) async {}
  @override
  bool get isAutomaticDataCollectionEnabled => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}