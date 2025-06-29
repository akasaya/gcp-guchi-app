import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
// import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
// import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/main.dart';
import 'package:frontend/models/graph_data.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/models/book_recommendation.dart';
import 'firebase_mock.dart';

// // --- ここからswipe_screen_test.dartと共通の偽Firebase実装 ---
// class FakeFirebaseAppPlatform extends Fake with MockPlatformInterfaceMixin implements FirebaseAppPlatform {
//   @override
//   final String name;
//   @override
//   final FirebaseOptions options;
//   FakeFirebaseAppPlatform({required this.name, required this.options});
// }

// class FakeFirebasePlatform extends Fake with MockPlatformInterfaceMixin implements FirebasePlatform {
//   static final Map<String, FirebaseAppPlatform> _apps = {};
//   @override
//   Future<FirebaseAppPlatform> initializeApp({String? name, FirebaseOptions? options}) async {
//     final appName = name ?? '[DEFAULT]';
//     final app = FakeFirebaseAppPlatform(name: appName, options: options!);
//     _apps[appName] = app;
//     return Future.value(app);
//   }
//   @override
//   FirebaseAppPlatform app([String name = '[DEFAULT]']) {
//     if (_apps.containsKey(name)) return _apps[name]!;
//     throw noAppExists(name);
//   }
//   @override
//   List<FirebaseAppPlatform> get apps => _apps.values.toList();
// }
// // --- ここまで偽のFirebase実装 ---

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
  setUpAll(() async {
    setupFirebaseMocks();
    await Firebase.initializeApp();
  });

  group('MyApp Authentication Flow', () {
    Future<SharedPreferences> setupMockSharedPreferences() async {
      SharedPreferences.setMockInitialValues({'onboarding_completed': true});
      return SharedPreferences.getInstance();
    }

    testWidgets('shows LoginScreen when user is not logged in', (WidgetTester tester) async {
      final mockAuth = MockFirebaseAuth();
      final mockPrefs = await setupMockSharedPreferences();

      // ★★★ 修正: MyApp() ではなく、test_main.dart の main() を呼び出すイメージ
      // ただし、直接呼び出すのではなく、ProviderScopeで上書きする
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            firebaseAuthProvider.overrideWithValue(mockAuth),
            sharedPreferencesProvider.overrideWith((ref) => mockPrefs),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          // ★★★ 修正: child を MyApp() にする
          child: const MyApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('shows HomeScreen when user is logged in', (WidgetTester tester) async {
      final mockUser = MockUser(uid: 'some_uid');
      final mockAuth = MockFirebaseAuth(mockUser: mockUser);
      final mockPrefs = await setupMockSharedPreferences();

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
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });
}