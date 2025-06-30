import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// import 'package:firebase_auth/firebase_auth.dart'; // ★ 削除
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/main.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/onboarding_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/models/book_recommendation.dart';
import 'package:frontend/models/graph_data.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'firebase_mock.dart';

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

class MockAuthNotifier extends StateNotifier<AuthState> implements AuthNotifier {
  MockAuthNotifier(super.state);
}

void main() {
  setupFirebaseMocks();

  Future<SharedPreferences> setupMockSharedPreferences({bool onboardingCompleted = false}) async {
    SharedPreferences.setMockInitialValues({'onboarding_completed': onboardingCompleted});
    return SharedPreferences.getInstance();
  }
  
  group('MyApp Authentication and Onboarding Flow', () {
    testWidgets('shows OnboardingScreen when onboarding is not completed', (WidgetTester tester) async {
      final mockUser = MockUser(isAnonymous: true, uid: 'some_uid');
      final authState = AuthState(status: AuthStatus.signedIn, user: mockUser);
      final mockAuthNotifier = MockAuthNotifier(authState);
      final mockPrefs = await setupMockSharedPreferences(onboardingCompleted: false);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuthNotifier), // ★ 修正
            sharedPreferencesProvider.overrideWith((ref) => mockPrefs),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );
      
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('shows HomeScreen when onboarding is completed and user is signed in', (WidgetTester tester) async {
      final mockUser = MockUser(isAnonymous: true, uid: 'some_uid');
      final authState = AuthState(status: AuthStatus.signedIn, user: mockUser);
      final mockAuthNotifier = MockAuthNotifier(authState);
      final mockPrefs = await setupMockSharedPreferences(onboardingCompleted: true);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuthNotifier), // ★ 修正
            sharedPreferencesProvider.overrideWith((ref) => mockPrefs),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(OnboardingScreen), findsNothing);
    });

    testWidgets('shows loading indicator during auth initialization', (WidgetTester tester) async {
      final authState = AuthState(status: AuthStatus.initializing);
      final mockAuthNotifier = MockAuthNotifier(authState);
      final mockPrefs = await setupMockSharedPreferences();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authNotifierProvider.overrideWith((ref) => mockAuthNotifier), // ★ 修正
            sharedPreferencesProvider.overrideWith((ref) => mockPrefs),
            apiServiceProvider.overrideWithValue(FakeApiService()),
          ],
          child: const MyApp(),
        ),
      );

      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}