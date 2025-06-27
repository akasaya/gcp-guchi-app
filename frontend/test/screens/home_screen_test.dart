import 'dart:async'; // ★ Completerを使うためにインポート

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';

import '../firebase_mock.dart';
import 'home_screen_test.mocks.dart';


// mockitoに、これから使う偽物のクラスの設計図を自動生成するように指示します
@GenerateMocks([ApiService, FirebaseAuth, User])
void main() {
  late MockApiService mockApiService;
  late MockFirebaseAuth mockFirebaseAuth;
  late MockUser mockUser;

  final testSuggestion = HomeSuggestion(
      title: '過去の対話の深掘り',
      nodeId: 'node_123',
      nodeLabel: 'テスト提案',
      subtitle: 'この前の会話を深掘りしませんか？');
  const testUserId = 'test_user_id';
  const testDisplayName = 'テストユーザー';

  setUpAll(() {
    setupFirebaseMocks();
  });

  Future<void> pumpHomeScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          apiService: mockApiService,
          auth: mockFirebaseAuth,
        ),
      ),
    );
  }

  setUp(() {
    mockApiService = MockApiService();
    mockFirebaseAuth = MockFirebaseAuth();
    mockUser = MockUser();

    when(mockUser.uid).thenReturn(testUserId);
    when(mockUser.displayName).thenReturn(testDisplayName);
    when(mockFirebaseAuth.currentUser).thenReturn(mockUser);
    when(mockFirebaseAuth.signOut()).thenAnswer((_) async => {});
    
    // ★ startSessionのデフォルトのモックは、すぐに完了するFutureを返すように修正
    when(mockApiService.startSession(any)).thenAnswer((_) async => {
          'session_id': 'session_123',
          'questions': [
            {'question_id': 'q1', 'question_text': '質問1です'}
          ]
        });
  });


  group('HomeScreen Widget Tests', () {
    testWidgets('初期表示：提案取得中はローディングインジケータが表示される', (tester) async {
      // Arrange: APIからの応答をわざと遅延させる
      when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async {
        await Future.delayed(const Duration(seconds: 1));
        return testSuggestion;
      });

      // Act
      await pumpHomeScreen(tester);

      // Assert: ローディング中であること
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('今日の話題の提案'), findsOneWidget);

      // Act: 時間を進めてAPI応答を待つ
      await tester.pumpAndSettle();

      // Assert: ローディングが完了し、提案が表示されること
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(testSuggestion.subtitle), findsOneWidget);
    });

    testWidgets('提案の取得に失敗した場合、エラーメッセージと再試行ボタンが表示される', (tester) async {
      // Arrange: APIがエラーを返すように設定
      when(mockApiService.getHomeSuggestionV2())
          .thenThrow(Exception('API Error'));

      // Act
      await pumpHomeScreen(tester);
      await tester.pumpAndSettle(); // 非同期処理（API呼び出し）の完了を待つ

      // Assert
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('提案の取得に失敗しました。'), findsOneWidget);
      expect(find.byKey(const Key('retry_button')), findsOneWidget);
    });

   testWidgets('再試行ボタンをタップすると、データ取得が再実行される', (tester) async {
      // Arrange: 最初の呼び出しは失敗させる
      when(mockApiService.getHomeSuggestionV2())
          .thenThrow(Exception('Initial API Error'));

      await pumpHomeScreen(tester);
      await tester.pumpAndSettle();
      expect(find.text('提案の取得に失敗しました。'), findsOneWidget);

      // Arrange: 2回目の呼び出しは成功させ、非同期のタイミングを適切に作る
      when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async {
        await Future.delayed(Duration.zero); // ★ 微小な遅延を入れてローディング状態を確実にテストする
        return testSuggestion;
      });

      // Act: 再試行ボタンをタップ
      await tester.tap(find.byKey(const Key('retry_button')));
      await tester.pump(); // 再取得が始まる（ローディング状態）

      // Assert: 再びローディングが表示される
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pumpAndSettle(); // 再取得の完了を待つ

      // Assert: エラーが消え、提案が表示される
      expect(find.text('提案の取得に失敗しました。'), findsNothing);
      expect(find.text(testSuggestion.subtitle), findsOneWidget);
    });

    testWidgets('トピックを選択すると「対話を開始する」ボタンが有効になる', (tester) async {
      // Arrange: 提案はない状態にする
      when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async => null);

      await pumpHomeScreen(tester);
      await tester.pumpAndSettle();

      // Assert: ボタンは最初は無効
      // ★ find.byKey を使ってボタンを正確に見つける
      ElevatedButton startButton = tester.widget(find.byKey(const Key('start_session_button')));
      expect(startButton.onPressed, isNull);

      // Act: トピック（仕事のこと）を選択
      await tester.tap(find.text('仕事のこと'));
      await tester.pump();

      // Assert: ボタンが有効になっている
      startButton = tester.widget(find.byKey(const Key('start_session_button')));
      expect(startButton.onPressed, isNotNull);
    });

    testWidgets('対話を開始ボタンをタップするとstartSessionが呼ばれ画面遷移する', (tester) async {
      // Arrange: APIの応答タイミングを制御するCompleterを用意
      final sessionCompleter = Completer<Map<String, dynamic>>();
      when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async => null);
      // Arrange: startSessionが呼ばれたら、Completerが完了するまで待つように設定
      when(mockApiService.startSession(any)).thenAnswer((_) => sessionCompleter.future);

      await pumpHomeScreen(tester);
      await tester.pumpAndSettle();

      // Act: トピックを選択してボタンをタップ
      await tester.tap(find.text('仕事のこと'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('start_session_button')));
      await tester.pump(); // ローディングダイアログの表示をスケジュール

      // Assert: APIの応答を待っている間、ローディングダイアログが表示されていることを確認
      expect(find.text('AIが質問を考えています...'), findsOneWidget);
      verify(mockApiService.startSession('仕事のこと')).called(1);

      // Act: APIの応答を完了させ、テストを進める
      sessionCompleter.complete({
        'session_id': 'session_123',
        'questions': [
          // ★ SwipeScreenが期待する正しいキーに修正
          {'question_id': 'q1', 'question_text': '質問1です'}
        ]
      });
      await tester.pumpAndSettle(); // 画面遷移のアニメーションが完了するのを待つ

      // Assert: HomeScreenは消え、SwipeScreenに遷移している
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(SwipeScreen), findsOneWidget);
      expect(find.text('質問1です'), findsOneWidget);
    });

    testWidgets('ログアウトボタンをタップするとsignOutが呼ばれる', (tester) async {
      // Arrange
      when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async => null);
      await pumpHomeScreen(tester);
      await tester.pumpAndSettle();

      // Act: ログアウトアイコンをタップ
      await tester.tap(find.byIcon(Icons.logout));
      await tester.pump();

      // Assert: 認証サービスのsignOutメソッドが呼ばれたことを確認
      verify(mockFirebaseAuth.signOut()).called(1);
    });
  });
}