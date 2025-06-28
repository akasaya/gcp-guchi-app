import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_mock.dart';

// --- テスト用の道具（モック）を定義 ---
class MockApiService extends Mock implements ApiService {}
class MockSharedPreferences extends Mock implements SharedPreferences {}

void main() {
  late MockApiService mockApiService;
  late MockSharedPreferences mockSharedPreferences;
  late MockFirebaseAuth mockAuth;
  late MockUser mockUser;

  // 全てのテストの前に一度だけ呼ばれるセットアップ
  setUpAll(() async {
    await setupFirebaseCoreMocks();
  });

  // 各テストの「直前」に毎回呼ばれるセットアップ
  setUp(() {
    // 道具を毎回新しく用意する
    mockApiService = MockApiService();
    mockSharedPreferences = MockSharedPreferences();
    mockUser = MockUser();
    mockAuth = MockFirebaseAuth(signedInUser: mockUser);

    // ★★★★★ これが最重要修正点 ★★★★★
    // 全てのテストケースで、API呼び出しに対する「デフォルトの偽の応答」を"あらかじめ"用意しておく。
    // これにより、テスト実行のどのタイミングでAPIが呼ばれても、テストがクラッシュしなくなる。
    // 各テストケースでは、このデフォルトの応答を必要に応じて上書きする。
    final defaultSuggestion = HomeSuggestion(title: 'Default', nodeId: 'default', nodeLabel: 'default', subtitle: 'Default');
    when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async => defaultSuggestion);

    // 他の道具のデフォルトの振る舞いも定義
    when(mockUser.displayName).thenReturn('テストユーザー');
    when(mockSharedPreferences.getBool('onboarding_completed')).thenReturn(true);
  });

  // `HomeScreen`をテスト用に起動するためのヘルパー関数
  Future<void> pumpHomeScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(mockApiService),
          firebaseAuthProvider.overrideWithValue(mockAuth),
          sharedPreferencesProvider.overrideWith((_) async => mockSharedPreferences),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
  }

  testWidgets('ローディング中にCircularProgressIndicatorが表示される', (tester) async {
    // APIがすぐには完了しない状況をモックで再現
    final completer = Completer<HomeSuggestion?>();
    when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) => completer.future);

    await pumpHomeScreen(tester);
    await tester.pump(); // setStateを反映させるために1フレーム進める

    // ローディング表示を確認
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('データ取得成功時に提案メッセージが表示される', (tester) async {
    // このテストケース用の「成功」の応答を上書き定義
    final suggestion = HomeSuggestion(title: 'Success', nodeId: 's_node1', nodeLabel: 's_label', subtitle: 'This is a success subtitle');
    when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async => suggestion);

    await pumpHomeScreen(tester);
    await tester.pumpAndSettle(); // 非同期処理（API呼び出し）の完了を待つ

    // 成功時のUIが表示されていることを確認
    expect(find.text('今日の話題の提案'), findsOneWidget);
    expect(find.text('過去の対話を深掘りしてみませんか'), findsOneWidget);
    expect(find.text('This is a success subtitle'), findsOneWidget);
  });

  testWidgets('データ取得失敗時にエラーメッセージが表示される', (tester) async {
    // このテストケース用の「失敗」の応答を上書き定義
    when(mockApiService.getHomeSuggestionV2()).thenThrow(Exception('API Error'));

    await pumpHomeScreen(tester);
    await tester.pumpAndSettle();

    // エラー時のUIが表示されていることを確認
    expect(find.text('提案の取得に失敗しました。'), findsOneWidget);
    expect(find.byKey(const Key('retry_button')), findsOneWidget);
  });

  testWidgets('再試行ボタンをタップすると再度APIが呼ばれる', (tester) async {
    // 1回目のAPI呼び出しは「失敗」するように定義
    when(mockApiService.getHomeSuggestionV2()).thenThrow(Exception('Initial Error'));

    await pumpHomeScreen(tester);
    await tester.pumpAndSettle();

    // エラーUIが表示され、APIが1回呼ばれたことを確認
    expect(find.text('提案の取得に失敗しました。'), findsOneWidget);
    verify(mockApiService.getHomeSuggestionV2()).called(1);

    // 2回目のAPI呼び出しは「成功」するように上書き定義
    final suggestion = HomeSuggestion(title: 'Retry Success', nodeId: 'r_node1', nodeLabel: 'r_label', subtitle: 'Success on retry');
    when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async => suggestion);

    // 再試行ボタンをタップ
    await tester.tap(find.byKey(const Key('retry_button')));
    await tester.pumpAndSettle();

    // APIが合計2回呼ばれたことを確認
    verify(mockApiService.getHomeSuggestionV2()).called(2);

    // 成功時のUIが表示されていることを確認
    expect(find.text('提案の取得に失敗しました。'), findsNothing);
    expect(find.text('Success on retry'), findsOneWidget);
  });
}