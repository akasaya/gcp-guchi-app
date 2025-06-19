import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';

import 'package:frontend/main.dart';
import 'package:frontend/models/graph_data.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';

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
  Future<GraphData> getAnalysisGraph() {
    throw UnimplementedError();
  }

  @override
  Future<NodeTapResponse?> getProactiveSuggestion() {
    throw UnimplementedError();
  }

  @override
  Future<ChatResponse> postChatMessage({
    required List<Map<String, String>> chatHistory,
    required String message,
    bool useRag = false,
    String? ragType,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<NodeTapResponse> handleNodeTap(String nodeLabel) {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> startSession(String topic) {
    throw UnimplementedError();
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
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> postSummary({
    required String sessionId,
    required List<Map<String, dynamic>> swipes,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<Map<String, dynamic>> continueSession({
    required String sessionId,
    required String insights, // ★★★ 型を `String` に修正 ★★★
  }) {
    throw UnimplementedError();
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