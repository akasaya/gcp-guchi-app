import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/main.dart';
import 'package:frontend/models/graph_data.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/models/book_recommendation.dart';
import 'firebase_mock.dart';

class FakeApiService implements ApiService {
  @override
  Future<HomeSuggestion?> getHomeSuggestion() async => null;
  @override
  Future<HomeSuggestion?> getHomeSuggestionV2() async => null;
  @override
  Future<List<String>> getTopicSuggestions() async => ['テスト提案1', 'テスト提案2'];
  @override
  Future<GraphData> getAnalysisGraph() async => GraphData(nodes: [], edges: []);
  @override
  Future<AnalysisSummary> getAnalysisSummary() async => AnalysisSummary(totalSessions: 0, topicCounts: []);
  @override
  Future<List<BookRecommendation>> getBookRecommendations() async => [];
  @override
  Future<NodeTapResponse?> getProactiveSuggestion() async => null;
  @override
  Future<ChatResponse> postChatMessage({
    required List<Map<String, String>> chatHistory,
    required String message,
    bool useRag = false,
    String? ragType,
  }) async => ChatResponse(response: 'dummy response', sources: []);
  @override
  Future<NodeTapResponse> handleNodeTap(String nodeLabel) async => NodeTapResponse(
        initialSummary: 'dummy', actions: [], nodeLabel: nodeLabel);
  @override
  Future<Map<String, dynamic>> startSession(String topic) async => {
      'session_id': 'dummy-session-id',
      'questions': [],
    };
  @override
  Future<void> recordSwipe({
    required String sessionId, required String questionId, required bool answer,
    required double hesitationTime, required int swipeSpeed, required int turn,
  }) async {}
  @override
  Future<void> postSummary({required String sessionId}) async {}
  @override
  Future<Map<String, dynamic>> continueSession({required String sessionId}) async => {};
}


void main() {
  // Firebaseのモックを初期化
  setupFirebaseMocks();

  // SharedPreferencesのモックをセットアップするヘルパー関数
  Future<SharedPreferences> setupMockSharedPreferences() async {
    SharedPreferences.setMockInitialValues({'onboarding_completed': true});
    return SharedPreferences.getInstance();
  }

  group('MyApp Authentication Flow', () {
    testWidgets('shows LoginScreen when user is not logged in', (WidgetTester tester) async {
      // 準備: 未ログイン状態のモックを作成
      final mockAuth = MockFirebaseAuth();
      final mockPrefs = await setupMockSharedPreferences();

      // 実行: MyAppウィジェットをレンダリング
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            sharedPreferencesProvider.overrideWith((ref) => mockPrefs),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );
      // アサーション: UIが安定するのを待ち、LoginScreenが表示されることを確認
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('shows HomeScreen when user is logged in', (WidgetTester tester) async {
      // 準備: ログイン済み状態のモックを作成
      final mockUser = MockUser(uid: 'some_uid', email: 'test@test.com');
      final mockAuth = MockFirebaseAuth(mockUser: mockUser, signedIn: true);
      final mockPrefs = await setupMockSharedPreferences();

      // 実行: MyAppウィジェットをレンダリング
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            sharedPreferencesProvider.overrideWith((ref) => mockPrefs),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );

      // ★★★ 修正点 ★★★
      // 非同期のauthStateChangesストリームが値を返すのを待つためにpumpを1回挟む
      await tester.pump();
      
      // アサーション: UIが安定するのを待ち、HomeScreenが表示されることを確認
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });
  });
}