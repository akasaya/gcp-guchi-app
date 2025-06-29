import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/models/chat_models.dart';
// import 'package:frontend/providers/session_provider.dart'; // 削除: ファイルが存在しない
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/summary_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_mock.dart';
import 'summary_screen_test.mocks.dart';

// --- START: home_screen_test.dart と共通のモッククラス定義 ---
// Note: 実際のプロジェクトでは共通のモックファイルを生成・利用するのが望ましい
class FakeUser extends Mock implements User {
  @override
  String get uid => 'test_uid';
}

class FakeFirebaseAuth extends Mock implements FirebaseAuth {
  final _user = FakeUser();
  @override
  Stream<User?> authStateChanges() => Stream.value(_user);
  @override
  User? get currentUser => _user;
}
// --- END: 共通のモッククラス定義 ---

@GenerateNiceMocks([
  MockSpec<ApiService>(),
  MockSpec<NavigatorObserver>(),
  MockSpec<SharedPreferences>(),
])
void main() {
  // ★★★ 修正: async を追加
  setUpAll(() async {
    setupFirebaseMocks();
    await Firebase.initializeApp();
  });

  late MockApiService mockApiService;
  late MockNavigatorObserver mockNavigatorObserver;
  late MockSharedPreferences mockSharedPreferences;
  late FakeFirebaseAuth fakeAuth;
  late FakeFirebaseFirestore fakeFirestore;

  setUp(() {
    mockApiService = MockApiService();
    mockNavigatorObserver = MockNavigatorObserver();
    mockSharedPreferences = MockSharedPreferences();
    fakeAuth = FakeFirebaseAuth();
    fakeFirestore = FakeFirebaseFirestore();

    // デフォルトでオンボーディングは完了済みとする
    when(mockSharedPreferences.getBool('onboarding_completed'))
        .thenReturn(true);
  });

  Future<void> pumpSummaryScreen(
    WidgetTester tester, {
    required String sessionId,
    Map<String, dynamic>? initialSessionData,
  }) async {
    // Firestoreのセッションデータを設定
    if (initialSessionData != null) {
    await fakeFirestore            // ← ★ユーザ階層をそろえる
        .collection('users')
        .doc(fakeAuth.currentUser!.uid)
        .collection('sessions')
        .doc(sessionId)
        .set(initialSessionData);
        }


    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(mockApiService),
          sharedPreferencesProvider
              .overrideWith((ref) => Future.value(mockSharedPreferences)),
          firebaseAuthProvider.overrideWithValue(fakeAuth),
        ],
        child: MaterialApp(
          // ★★★ 修正: 'home'と'routes["/"]'は共存できないため、'home'を削除し
          // 'initialRoute'を使用する
          initialRoute: '/',
          navigatorObservers: [mockNavigatorObserver],
          routes: {
            '/': (context) => SummaryScreen(
                  sessionId: sessionId,
                  firestore: fakeFirestore,
                  apiService: mockApiService,
                ),
            '/home': (context) => const HomeScreen(),
          },
        ),
      ),
    );
  }

  group('SummaryScreen Widget Tests', () {
    const sessionId = 'test-session-id';
    final completedSessionData = {
      'status': 'completed',
      'title': 'テストセッション',
      'latest_insights': 'これが分析結果です。\n\n## 詳細\n- 項目1\n- 項目2',
      'turn': 2,
      'max_turns': 5,
    };
    final errorSessionData = {
      'status': 'error',
      'error_message': '分析中にエラーが発生しました',
    };
    final loadingSessionData = {'status': 'processing'};

    testWidgets('ローディング中にインジケータが表示される', (tester) async {
      await pumpSummaryScreen(tester,
          sessionId: sessionId, initialSessionData: loadingSessionData);

      // ローディングインジケータが表示される
      expect(find.byType(SpinKitFadingCube), findsOneWidget);
      expect(find.text('AIがあなたの考えを分析中...'), findsOneWidget);
    });

    testWidgets('データ取得成功時にサマリーが表示される', (tester) async {
      await pumpSummaryScreen(tester,
          sessionId: sessionId, initialSessionData: completedSessionData);

      // データ取得完了まで待機
      await tester.pumpAndSettle();

      // サマリーが表示される
      expect(find.text('テストセッション'), findsOneWidget);
      expect(find.textContaining('これが分析結果です', findRichText: true),
          findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'さらに深掘りする (残り3回)'),
          findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'ホームに戻る'), findsOneWidget);
    });

    testWidgets('データ取得失敗時にエラーメッセージが表示される', (tester) async {
      await pumpSummaryScreen(tester,
          sessionId: sessionId, initialSessionData: errorSessionData);
      await tester.pumpAndSettle();

      expect(find.text('分析結果の取得に失敗しました: 分析中にエラーが発生しました'), findsOneWidget);
    });

    testWidgets('「さらに深掘りする」をタップするとAPIが呼ばれ、遷移する', (tester) async {
      // APIのモックを設定
      when(mockApiService.continueSession(sessionId: sessionId))
          .thenAnswer((_) async => {
                'questions': [
                  {'question_id': 'q1', 'question_text': 'これは質問1ですか？'},
                  {'question_id': 'q2', 'question_text': 'これは質問2ですか？'}
                ],
                'turn': 3,
              });

      await pumpSummaryScreen(tester,
          sessionId: sessionId, initialSessionData: completedSessionData);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ElevatedButton, 'さらに深掘りする (残り3回)'));

      // API呼び出しと画面遷移の完了を待つ
      await tester.pumpAndSettle();

      // ★★★ 修正: 遷移後の画面（SwipeScreen）のコンテンツを直接検証する ★★★
      expect(find.text('質問 1 / 2'), findsOneWidget);

      // APIが1回呼ばれたことを確認
      verify(mockApiService.continueSession(sessionId: sessionId)).called(1);
    });


    testWidgets('「ホームに戻る」をタップするとHomeScreenに遷移する', (tester) async {
      // ホーム画面のプロバイダーもモックしておく
      when(mockApiService.getHomeSuggestionV2()).thenAnswer((_) async =>
          HomeSuggestion(
              title: 'T', subtitle: 'S', nodeId: 'n', nodeLabel: 'nl'));

      await pumpSummaryScreen(tester,
          sessionId: sessionId, initialSessionData: completedSessionData);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'ホームに戻る'));
      await tester.pumpAndSettle();

      // HomeScreenへの遷移を検証
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });
}