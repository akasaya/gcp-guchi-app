import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';

import 'package:frontend/main.dart';
import 'package:frontend/models/graph_data.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';
// import 'package:frontend/models/analysis_models.dart'; // ★★★ 削除されたファイルなので、この行を削除します ★★★
import 'package:frontend/models/book_recommendation.dart';

/// Firebaseのネイティブ通信を偽装するクラス
class MockFirebasePlatform extends FirebasePlatform {
  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    return FirebaseAppPlatform(
      name ?? defaultFirebaseAppName,
      options ?? const FirebaseOptions(
        apiKey: 'mock-api-key',
        appId: 'mock-app-id',
        messagingSenderId: 'mock-sender-id',
        projectId: 'mock-project-id',
      ),
    );
  }

  @override
  FirebaseAppPlatform app([String name = defaultFirebaseAppName]) {
    return FirebaseAppPlatform(
      name,
      const FirebaseOptions(
        apiKey: 'mock-api-key',
        appId: 'mock-app-id',
        messagingSenderId: 'mock-sender-id',
        projectId: 'mock-project-id',
      ),
    );
  }
}

/// ApiServiceの偽物（フェイク）クラスを定義します。
/// ApiServiceが持つすべてのメソッドを、正しい引数でダミーとして実装します。
class FakeApiService implements ApiService {
  @override
  Future<HomeSuggestion?> getHomeSuggestion() async {
    return Future.value(null);
  }
  
  @override
  Future<HomeSuggestion?> getHomeSuggestionV2() async {
    return Future.value(null);
  }

  // ★★★ 修正: 正しいモデル(chat_models.dart)を使って、エラーを投げないように実装します ★★★
  @override
  Future<AnalysisSummary> getAnalysisSummary() {
    return Future.value(AnalysisSummary(totalSessions: 0, topicCounts: []));
  }
  
  // ★★★ 追加: ApiServiceに追加された新しいメソッドを、テスト用に実装します ★★★
  @override
  Future<List<String>> getTopicSuggestions() {
    return Future.value(['テスト提案1', 'テスト提案2']);
  }

  @override
  Future<List<BookRecommendation>> getBookRecommendations() {
    return Future.value([]);
  }

  @override
  Future<GraphData> getAnalysisGraph() {
    return Future.value(GraphData(nodes: [], edges: []));
  }

  @override
  Future<NodeTapResponse?> getProactiveSuggestion() {
    return Future.value(null);
  }

  @override
  Future<ChatResponse> postChatMessage({
    required List<Map<String, String>> chatHistory,
    required String message,
    bool useRag = false,
    String? ragType,
  }) {
    // 実際には使われないので、ダミーの応答を返します
    return Future.value(ChatResponse(response: 'dummy response'));
  }

  @override
  Future<NodeTapResponse> handleNodeTap(String nodeLabel) {
    // 実際には使われないので、ダミーの応答を返します
    return Future.value(NodeTapResponse(
        initialSummary: 'dummy', actions: [], nodeLabel: nodeLabel));
  }

  @override
  Future<Map<String, dynamic>> startSession(String topic) {
    // 実際には使われないので、ダミーの応答を返します
    return Future.value({
      'session_id': 'dummy-session-id',
      'questions': [],
    });
  }

  @override
  Future<void> recordSwipe({
    required String sessionId,
    required String questionId,
    required bool answer,
    required double hesitationTime,
    required int swipeSpeed,
    required int turn,
  }) {
    return Future.value();
  }

  @override
  Future<Map<String, dynamic>> postSummary({
    required String sessionId,
  }) {
    return Future.value({});
  }

  @override
  Future<Map<String, dynamic>> continueSession({
    required String sessionId,
  }) {
    return Future.value({});
  }
}


void main() {
  // すべてのテストが実行される前に、一度だけFirebaseのテスト環境をセットアップします。
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FirebasePlatform.instance = MockFirebasePlatform();
    await Firebase.initializeApp();
  });

  group('MyApp Authentication Flow', () {
    testWidgets('shows LoginScreen when user is not logged in',
        (WidgetTester tester) async {
      final mockAuth = MockFirebaseAuth(signedIn: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [firebaseAuthProvider.overrideWithValue(mockAuth)],
          child: const MyApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('shows HomeScreen when user is logged in',
        (WidgetTester tester) async {
      final mockAuth = MockFirebaseAuth(signedIn: true);
      final fakeApiService = FakeApiService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            apiServiceProvider.overrideWithValue(fakeApiService),
          ],
          child: const MyApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });
  });
}