import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:dio/dio.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/graph_data.dart';
import 'package:frontend/models/chat_models.dart'; // この行を追加
import 'package:frontend/models/book_recommendation.dart'; 
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

import 'api_service_test.mocks.dart';

// DioとFirebaseAppCheckをモック化するためのアノテーション
@GenerateMocks([Dio, FirebaseAppCheck])
void main() {
  late ApiService apiService;
  late MockDio mockDio;
  late MockFirebaseAuth mockAuth;
  late MockFirebaseAppCheck mockAppCheck;

  setUp(() {
    // 1. 各モックを初期化
    mockDio = MockDio();
    mockAppCheck = MockFirebaseAppCheck();
    
    final user = MockUser(
      isAnonymous: false,
      uid: 'some_uid',
      email: 'test@example.com',
      displayName: 'Test User',
    );
    mockAuth = MockFirebaseAuth(mockUser: user, signedIn: true);

    // 2. ApiServiceのコンストラクタで使われるプロパティのスタブを先に設定
    when(mockDio.options).thenReturn(BaseOptions());
    when(mockDio.interceptors).thenReturn(Interceptors()); // interceptorsのスタブを追加

    // 3. スタブ設定後にApiServiceをインスタンス化
    apiService = ApiService(
      dio: mockDio,
      auth: mockAuth,
      // appCheck: mockAppCheck, // ★★★ 削除されたパラメータ
    );
    
    // その他のスタブ設定
    when(mockAppCheck.getToken(any)).thenAnswer((_) async => 'fake-app-check-token');
  });

  group('ApiService Tests', () {
    test('getAnalysisGraphが成功した時、GraphDataを返すこと', () async {
      // --- Arrange (準備) ---
      final responsePayload = {
        "nodes": [
          {"id": "仕事の悩み", "type": "topic", "size": 20},
          {"id": "人間関係", "type": "issue", "size": 15}
        ],
        "edges": [
          {"source": "仕事の悩み", "target": "人間関係", "weight": 2}
        ]
      };
      
      when(mockDio.get('/api/analysis/graph')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/analysis/graph'),
          data: responsePayload,
          statusCode: 200,
        ),
      );
      
      // --- Act (実行) ---
      final result = await apiService.getAnalysisGraph();
      
      // --- Assert (検証) ---
      expect(result, isA<GraphData>());
      expect(result.nodes.length, 2);
      expect(result.nodes[0].id, '仕事の悩み');
    });

    test('getAnalysisGraphが失敗した時、Exceptionをスローすること', () async {
      // --- Arrange (準備) ---
      when(mockDio.get('/api/analysis/graph')).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/analysis/graph'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/analysis/graph'),
            statusCode: 500,
            data: {'error': 'Internal Server Error'},
          ),
        ),
      );

      // --- Act & Assert (実行と検証) ---
      expect(
        () async => await apiService.getAnalysisGraph(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('getAnalysisSummary', () {
    test('成功した場合、AnalysisSummaryを返すこと', () async {
      // Arrange
      final responsePayload = {
        "total_sessions": 5,
        "topic_counts": [
          {"topic": "仕事", "count": 3},
          {"topic": "プライベート", "count": 2}
        ]
      };
      when(mockDio.get('/api/analysis/summary')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/analysis/summary'),
          data: responsePayload,
          statusCode: 200,
        ),
      );

      // Act
      final result = await apiService.getAnalysisSummary();

      // Assert
      expect(result, isA<AnalysisSummary>());
      expect(result.totalSessions, 5);
      expect(result.topicCounts.length, 2);
    });

    test('失敗した場合、Exceptionをスローすること', () async {
      // Arrange
      when(mockDio.get('/api/analysis/summary')).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/analysis/summary'),
        ),
      );

      // Act & Assert
      expect(
        () async => await apiService.getAnalysisSummary(),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('startSession', () {
    test('成功した場合、セッション情報をMapで返すこと', () async {
      // Arrange
      const topic = '新しいトピック';
      final responsePayload = {
        'session_id': 'new_session_123',
        'questions': [
          {'question_id': 'q1', 'question_text': '質問1ですか？'},
        ]
      };
      when(mockDio.post(
        '/api/session/start',
        data: {'topic': topic},
      )).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/session/start'),
          data: responsePayload,
          statusCode: 200,
        ),
      );

      // Act
      final result = await apiService.startSession(topic);

      // Assert
      expect(result, isA<Map<String, dynamic>>());
      expect(result['session_id'], 'new_session_123');
    });

    test('失敗した場合、Exceptionをスローすること', () async {
      // Arrange
      const topic = '失敗するトピック';
      when(mockDio.post(
        '/api/session/start',
        data: {'topic': topic},
      )).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/session/start'),
        ),
      );

      // Act & Assert
      expect(
        () async => await apiService.startSession(topic),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('recordSwipe', () {
    const sessionId = 'test_session_id';
    const questionId = 'q1';
    const answer = true;
    const hesitationTime = 123.4;
    const swipeSpeed = 500;
    const turn = 1;

    test('成功した場合、例外をスローしないこと', () async {
      // Arrange
      when(mockDio.post(
        '/api/session/$sessionId/swipe',
        data: {
          'question_id': questionId,
          'answer': answer,
          'hesitation_time': hesitationTime,
          'speed': swipeSpeed,
          'turn': turn,
        },
      )).thenAnswer(
        (_) async => Response(
          requestOptions:
              RequestOptions(path: '/api/session/$sessionId/swipe'),
          statusCode: 200,
        ),
      );

      // Act & Assert
      expect(
          () async => await apiService.recordSwipe(
                sessionId: sessionId,
                questionId: questionId,
                answer: answer,
                hesitationTime: hesitationTime,
                swipeSpeed: swipeSpeed,
                turn: turn,
              ),
          returnsNormally);
    });

    test('失敗した場合、Exceptionをスローすること', () async {
      // Arrange
      when(mockDio.post(
        '/api/session/$sessionId/swipe',
        data: anyNamed('data'),
      )).thenThrow(
        DioException(
          requestOptions:
              RequestOptions(path: '/api/session/$sessionId/swipe'),
        ),
      );

      // Act & Assert
      expect(
        () async => await apiService.recordSwipe(
          sessionId: sessionId,
          questionId: questionId,
          answer: answer,
          hesitationTime: hesitationTime,
          swipeSpeed: swipeSpeed,
          turn: turn,
        ),
        throwsA(isA<Exception>()),
      );
    });
  });
  group('postSummary', () {
    const sessionId = 'test-session-id';

    test('成功した場合、正常に完了すること', () async {
      // Arrange
      // 成功した場合（ステータスコード200）を想定
      when(mockDio.post('/api/session/$sessionId/summary')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/session/$sessionId/summary'),
          statusCode: 200,
        ),
      );

      // Act & Assert
      // 例外がスローされないことを確認
      expect(
        () async => await apiService.postSummary(sessionId: sessionId),
        returnsNormally,
      );
    });

    test('失敗した場合、例外がスローされないこと（内部でキャッチするため）', () async {
      // Arrange
      // 失敗した場合を想定
      when(mockDio.post('/api/session/$sessionId/summary')).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/session/$sessionId/summary'),
        ),
      );

      // Act & Assert
      // このメソッドは内部でエラーをキャッチして握りつぶす設計なので、
      // 失敗時も例外がスローされないことを確認する
      expect(
        () async => await apiService.postSummary(sessionId: sessionId),
        returnsNormally,
      );
    });
  });

  group('continueSession', () {
    const sessionId = 'test-session-id';

    test('成功した場合、セッション情報をMapで返すこと', () async {
      // Arrange
      final responsePayload = {'session_id': sessionId, 'new_question': '新しい質問'};
      when(mockDio.post('/api/session/$sessionId/continue')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/session/$sessionId/continue'),
          data: responsePayload,
          statusCode: 200,
        ),
      );

      // Act
      final result = await apiService.continueSession(sessionId: sessionId);

      // Assert
      expect(result, responsePayload);
    });

    test('失敗した場合、Exceptionをスローすること', () async {
      // Arrange
      when(mockDio.post('/api/session/$sessionId/continue')).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/session/$sessionId/continue'),
        ),
      );

      // Act & Assert
      expect(
        () async => await apiService.continueSession(sessionId: sessionId),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('getBookRecommendations', () {
    test('成功した場合、BookRecommendationのリストを返すこと', () async {
      // Arrange
      final responsePayload = [
        {'title': 'Book 1', 'author': 'Author 1', 'reason': 'Reason 1', 'search_url': 'url1'},
        {'title': 'Book 2', 'author': 'Author 2', 'reason': 'Reason 2', 'search_url': 'url2'},
      ];
      when(mockDio.get('/api/analysis/book_recommendations')).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/analysis/book_recommendations'),
          data: responsePayload,
          statusCode: 200,
        ),
      );

      // Act
      final result = await apiService.getBookRecommendations();

      // Assert
      expect(result, isA<List<BookRecommendation>>());
      expect(result.length, 2);
      expect(result.first.title, 'Book 1');
    });

    test('失敗した場合、Exceptionをスローすること', () async {
      // Arrange
      when(mockDio.get('/api/analysis/book_recommendations')).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: '/api/analysis/book_recommendations'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/analysis/book_recommendations'),
            data: {'error': 'テストエラー'},
            statusCode: 500,
          ),
        ),
      );

      // Act & Assert
      expect(
        () async => await apiService.getBookRecommendations(),
        throwsA(isA<Exception>()),
      );
    });
  });
}