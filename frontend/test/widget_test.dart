import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/main.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/onboarding_screen.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/models/book_recommendation.dart';
import 'package:frontend/models/graph_data.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'firebase_mock.dart'; // ★ 相対パスに修正

// FakeApiServiceは変更なし
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
  // Firebaseのモック初期化
  setupFirebaseMocks();

  Future<SharedPreferences> setupMockSharedPreferences({bool onboardingCompleted = false}) async {
    SharedPreferences.setMockInitialValues({'onboarding_completed': onboardingCompleted});
    return SharedPreferences.getInstance();
  }
  
  group('MyApp Authentication and Onboarding Flow', () {
    final mockUser = MockUser(
      isAnonymous: false,
      uid: 'some_uid',
      email: 'test@example.com',
      displayName: 'Test User',
    );

    testWidgets('shows OnboardingScreen when onboarding is not completed (user signed in)', (WidgetTester tester) async {
      final mockPrefs = await setupMockSharedPreferences(onboardingCompleted: false);
      
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateChangesProvider.overrideWith((ref) => Stream.value(mockUser)),
            sharedPreferencesProvider.overrideWith((ref) => Future.value(mockPrefs)),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );
      
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.byType(LoginScreen), findsNothing);
    });

    testWidgets('shows OnboardingScreen when onboarding is not completed (user signed out)', (WidgetTester tester) async {
      final mockPrefs = await setupMockSharedPreferences(onboardingCompleted: false);
      
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateChangesProvider.overrideWith((ref) => Stream.value(null)),
            sharedPreferencesProvider.overrideWith((ref) => Future.value(mockPrefs)),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );
      
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
    });


    testWidgets('shows HomeScreen when onboarding is completed and user is signed in', (WidgetTester tester) async {
      final mockPrefs = await setupMockSharedPreferences(onboardingCompleted: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateChangesProvider.overrideWith((ref) => Stream.value(mockUser)),
            sharedPreferencesProvider.overrideWith((ref) => Future.value(mockPrefs)),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(LoginScreen), findsNothing);
    });

    testWidgets('shows LoginScreen when onboarding is completed and user is signed out', (WidgetTester tester) async {
      final mockPrefs = await setupMockSharedPreferences(onboardingCompleted: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateChangesProvider.overrideWith((ref) => Stream.value(null)),
            sharedPreferencesProvider.overrideWith((ref) => Future.value(mockPrefs)),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('shows loading indicator while auth state is loading', (WidgetTester tester) async {
      final mockPrefs = await setupMockSharedPreferences();
      
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateChangesProvider.overrideWith((ref) => const Stream.empty()),
            sharedPreferencesProvider.overrideWith((ref) => Future.value(mockPrefs)),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}