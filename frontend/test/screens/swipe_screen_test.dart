import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
//import 'package:frontend/models/book_recommendation.dart';
import 'package:frontend/screens/summary_screen.dart';
import 'package:frontend/screens/swipe_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'swipe_screen_test.mocks.dart';

// --- ここから最終修正済みの偽Firebase実装 ---

// ★★★ 全ての悲劇の元凶であった、欠落していた「印」を追加 ★★★
// プラットフォームインターフェースの偽物であることを示すための`MockPlatformInterfaceMixin`が
// このクラスに抜けていたことが、'implements'エラーの根本原因でした。
class FakeFirebaseAppPlatform extends Fake with MockPlatformInterfaceMixin implements FirebaseAppPlatform {
  @override
  final String name;
  @override
  final FirebaseOptions options;
  FakeFirebaseAppPlatform({required this.name, required this.options});
}

class FakeFirebasePlatform extends Fake with MockPlatformInterfaceMixin implements FirebasePlatform {
  static final Map<String, FirebaseAppPlatform> _apps = {};

  @override
  Future<FirebaseAppPlatform> initializeApp({
    String? name,
    FirebaseOptions? options,
  }) async {
    final appName = name ?? '[DEFAULT]';
    final app = FakeFirebaseAppPlatform(name: appName, options: options!);
    _apps[appName] = app;
    return Future.value(app);
  }

  @override
  FirebaseAppPlatform app([String name = '[DEFAULT]']) {
    if (_apps.containsKey(name)) {
      return _apps[name]!;
    }
    throw noAppExists(name);
  }

  @override
  List<FirebaseAppPlatform> get apps => _apps.values.toList();
}
// --- ここまで偽のFirebase実装 ---

@GenerateNiceMocks([MockSpec<ApiService>(), MockSpec<NavigatorObserver>()])
void main() {
  setUpAll(() async {
    FirebasePlatform.instance = FakeFirebasePlatform();
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'fake',
        appId: 'fake',
        messagingSenderId: 'fake',
        projectId: 'fake',
      ),
    );
  });

  const sessionId = 'test-session-id';
  final questions = [
    {'question_id': 'q1', 'question_text': '質問1'},
    {'question_id': 'q2', 'question_text': '質問2'},
  ];

  late MockApiService mockApiService;
  late FakeFirebaseFirestore fakeFirestore;
  late MockNavigatorObserver mockNavigatorObserver;

  setUp(() {
    mockApiService = MockApiService();
    fakeFirestore = FakeFirebaseFirestore();
    mockNavigatorObserver = MockNavigatorObserver();

    when(mockApiService.postSummary(sessionId: anyNamed('sessionId')))
        .thenAnswer((_) async => {});

    when(mockApiService.recordSwipe(
      sessionId: anyNamed('sessionId'),
      questionId: anyNamed('questionId'),
      answer: anyNamed('answer'),
      hesitationTime: anyNamed('hesitationTime'),
      swipeSpeed: anyNamed('swipeSpeed'),
      turn: anyNamed('turn'),
    )).thenAnswer((_) async {});
  });

  Future<void> pumpSwipeScreen(WidgetTester tester,
      {NavigatorObserver? navigatorObserver}) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorObservers:
              navigatorObserver != null ? [navigatorObserver] : [],
          home: SwipeScreen(
            sessionId: sessionId,
            questions: questions,
            apiService: mockApiService,
            firestore: fakeFirestore,
          ),
        ),
      ),
    );
  }

  group('SwipeScreen Widget Tests', () {
    testWidgets('初期表示：最初の質問とボタンが表示されること', (WidgetTester tester) async {
      await pumpSwipeScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('質問 1 / 2'), findsOneWidget);
      expect(find.text('質問1'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('「はい」ボタンをタップするとrecordSwipeが呼ばれ、次の質問が表示される',
        (WidgetTester tester) async {
      await pumpSwipeScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();

      verify(mockApiService.recordSwipe(
        sessionId: sessionId,
        questionId: 'q1',
        answer: true,
        hesitationTime: anyNamed('hesitationTime'),
        swipeSpeed: anyNamed('swipeSpeed'),
        turn: 1,
      )).called(1);

      expect(find.text('質問 2 / 2'), findsOneWidget);
      expect(find.text('質問2'), findsOneWidget);
      expect(find.text('質問1'), findsNothing);
    });

    testWidgets('全ての質問に答えるとpostSummaryが呼ばれ、SummaryScreenへ遷移すること',
        (WidgetTester tester) async {
      // Arrange
      await pumpSwipeScreen(tester, navigatorObserver: mockNavigatorObserver);
      await tester.pumpAndSettle();

      // Act
      await tester.tap(find.byIcon(Icons.check));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      // Assert
      verify(mockApiService.postSummary(sessionId: sessionId)).called(1);
      verify(mockNavigatorObserver.didPush(argThat(isA<MaterialPageRoute>()), any)).called(1);
      expect(find.byType(SwipeScreen), findsNothing);
      expect(find.byType(SummaryScreen), findsOneWidget);
    });
  });
}