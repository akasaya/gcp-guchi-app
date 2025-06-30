import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';

// ─ 1. mock 定義 ────────────────────────────────────
// mocktail を使い、テストで使う偽のクラスを定義します。
class MockApiService extends Mock implements ApiService {}
class MockAuthService extends Mock implements AuthService {}
class MockSharedPreferences extends Mock implements SharedPreferences {}

void main() {
  // ─ 2. テストで使うモックの変数を準備 ───────────────
  late MockApiService mockApiService;
  late MockAuthService mockAuthService;
  late MockSharedPreferences mockSharedPreferences;

  // テスト全体で使うログイン済みのユーザーモック
  final mockUser = MockUser(uid: 'uid', displayName: 'テストユーザー');

  // ─ 3. 各テストの前にモックを初期化 ────────────────
  // testWidgets が実行されるたびに、この setUp ブロックが呼ばれ、
  // モックが新鮮な状態にリセットされます。
  setUp(() {
    mockApiService = MockApiService();
    mockAuthService = MockAuthService();
    mockSharedPreferences = MockSharedPreferences();

    // SharedPreferencesのデフォルトの挙動（オンボーディング完了済み）を設定します。
    // これにより、テストは常に HomeScreen を表示しようとします。
    when(() => mockSharedPreferences.getBool('onboarding_completed'))
        .thenReturn(true);
  });

  // ─ 4. テストウィジェットを生成するヘルパー関数 ─────
  // 毎回 ProviderScope を書く手間を省き、テストコードをスッキリさせます。
  Widget createTestWidget() {
    return ProviderScope(
      overrides: [
        // アプリケーションで使われているProviderをすべてモックに差し替えます。
        apiServiceProvider.overrideWithValue(mockApiService),
        authServiceProvider.overrideWithValue(mockAuthService),
        // ログイン状態をシミュレートするために、常にmockUserを返すStreamを提供
        authStateChangesProvider.overrideWith((ref) => Stream.value(mockUser)),
        // SharedPreferencesのモックを提供
        sharedPreferencesProvider.overrideWith((ref) async => mockSharedPreferences),
      ],
      // ★★★★★ 最重要ポイント ★★★★★
      // HomeScreen単体ではなく、MyApp全体をテスト対象にします。
      // これにより、AuthWrapperなどの実際のロジックを経由するため、
      // より本番に近い、信頼性の高いテストになります。
      child: const MyApp(),
    );
  }

  // ─ 5. 各テストケース ──────────────────────────────

  testWidgets('データ取得中にローディングインジケータが表示される', (tester) async {
    // APIがすぐには応答を返さない（ずっと待機している）状況をシミュレートします。
    final completer = Completer<HomeSuggestion?>();
    when(() => mockApiService.getHomeSuggestionV2())
        .thenAnswer((_) => completer.future);

    await tester.pumpWidget(createTestWidget());
    // pump()を1回呼ぶことで、最初のフレームを描画させます。
    // これでAuthWrapperなどが動き始めます。
    await tester.pump();
    // もう一度 pump() を呼んで、プロバイダーの解決などを待ちます。
    await tester.pump();

    // ローディングインジケータが表示されていることを確認します。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // テスト終了後にCompleterを完了させて、エラーを防ぎます。
    completer.complete(null);
  });

  testWidgets('データ取得成功時に提案内容が表示される', (tester) async {
    // APIが成功応答を返すように設定します。
    final suggestion = HomeSuggestion(
        title: 'Success', nodeId: 'id', nodeLabel: 'lbl', subtitle: '提案のサブタイトル');
    when(() => mockApiService.getHomeSuggestionV2())
        .thenAnswer((_) async => suggestion);

    await tester.pumpWidget(createTestWidget());
    // pumpAndSettle() は、すべてのアニメーションや非同期処理が完了するまで待ちます。
    await tester.pumpAndSettle();

    // 提案のヘッダーとサブタイトルが表示されていることを確認します。
    expect(find.text('話題の提案'), findsOneWidget);
    expect(find.text('提案のサブタイトル'), findsOneWidget);
  });

  testWidgets('データ取得失敗時にエラーメッセージが表示される', (tester) async {
    // APIがエラーを投げるように設定します。
    when(() => mockApiService.getHomeSuggestionV2())
        .thenThrow(Exception('API error'));

    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    // エラーメッセージと再試行ボタンが表示されていることを確認します。
    expect(find.text('提案の取得に失敗しました。'), findsOneWidget);
    expect(find.byKey(const Key('retry_button')), findsOneWidget);
  });

testWidgets('再試行ボタンをタップすると再度APIが呼ばれる', (tester) async {
    // 1回目のAPI呼び出しは失敗するように設定します。
    when(() => mockApiService.getHomeSuggestionV2())
        .thenThrow(Exception('First call failed'));

    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    // 1回目のAPI呼び出しが行われたことを確認します。
    verify(() => mockApiService.getHomeSuggestionV2()).called(1);
    // 再試行ボタンが表示されていることを確認します。
    expect(find.byKey(const Key('retry_button')), findsOneWidget);

    // 2回目のAPI呼び出しは成功するように設定します。
    final retrySuggestion = HomeSuggestion(
        title: 'Retry', nodeId: 'r', nodeLabel: 'r', subtitle: '再試行成功');
    when(() => mockApiService.getHomeSuggestionV2())
        .thenAnswer((_) async => retrySuggestion);

    // 再試行ボタンをタップします。
    await tester.tap(find.byKey(const Key('retry_button')));
    await tester.pumpAndSettle();

    // ★★★★★ 修正ポイント ★★★★★
    // タップ後、API呼び出しが「さらに1回」行われたことを確認します。
    verify(() => mockApiService.getHomeSuggestionV2()).called(1);
    
    // 成功時のUIが表示され、再試行ボタンが消えたことを確認します。
    expect(find.text('再試行成功'), findsOneWidget);
    expect(find.byKey(const Key('retry_button')), findsNothing); // 再試行ボタンは消える
  });
}