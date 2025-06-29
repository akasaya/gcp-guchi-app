import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/graph_data.dart';
import '../models/chat_models.dart';
import '../models/book_recommendation.dart';

// ApiServiceをアプリケーション全体で利用可能にするためのProvider
final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

class ApiService {
  late final Dio _dio;
  late final FirebaseAuth _auth;
  //late final FirebaseAppCheck _appCheck;

  ApiService({Dio? dio, FirebaseAuth? auth}) {
    _dio = dio ?? Dio();
    _auth = auth ?? FirebaseAuth.instance;
    //_appCheck = appCheck ?? FirebaseAppCheck.instance;
    // --- ベースURLとタイムアウト設定 ---

    // ★★★ 修正点1: 本番環境のBaseURLを空にする ★★★
    // これにより、リクエストは自分自身のホスト（Firebase Hosting）に送られるようになります。
    final String baseUrl = (kDebugMode && defaultTargetPlatform == TargetPlatform.android)
        ? 'http://10.0.2.2:8080' // Androidエミュレータ
        : (kDebugMode)
            ? 'http://localhost:8080' // iOSシミュレータ、Web、デスクトップ
            : ""; // 本番環境 (Firebase Hosting)

    _dio.options.baseUrl = baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 60);
    _dio.options.receiveTimeout = const Duration(seconds: 60); // AIの応答時間を考慮

    // --- Interceptorによる認証トークンの自動付与 ---
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final user = _auth.currentUser;
        if (user != null) {
          try {
            final token = await user.getIdToken(true); // トークンを強制リフレッシュ
            options.headers['Authorization'] = 'Bearer $token';
            if (kIsWeb || kReleaseMode) {
              final appCheckToken = await FirebaseAppCheck.instance.getToken(true);
              if (appCheckToken != null) {
                options.headers['X-Firebase-AppCheck'] = appCheckToken;
              }
            }
          } catch (e) {
            return handler.reject(DioException(requestOptions: options, error: e));
          }
        }
        return handler.next(options);
      },
      onError: (DioException e, handler) {
        return handler.next(e);
      },
    ));
  }

  // ★★★ 修正点2: 以降、すべてのパスの先頭に '/api' を追加 ★★★

  Future<HomeSuggestion?> getHomeSuggestionV2() async {
    try {
      final response = await _dio.get('/api/home/suggestion_v2');
      if (response.statusCode == 200 && response.data != null) {
        return HomeSuggestion.fromJson(response.data);
      }
      return null;
    } catch (e) {
      debugPrint('ホーム画面の提案(v2)取得に失敗: $e');
      return null;
    }
  }

    Future<List<String>> getTopicSuggestions() async {
    try {
      final response = await _dio.get('/api/session/topic_suggestions');
      if (response.statusCode == 200 && response.data != null) {
        // バックエンドから返される {"suggestions": ["提案1", "提案2", ...]} を処理
        final List<dynamic> suggestions = response.data['suggestions'];
        // 文字列のリストに変換して返す
        return suggestions.map((s) => s.toString()).toList();
      }
      return [];
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? 'トピック提案の取得に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      throw Exception('予期せぬエラーが発生しました: $e');
    }
  }

  Future<HomeSuggestion?> getHomeSuggestion() async {
    try {
      final response = await _dio.get('/api/home/suggestion');
      if (response.statusCode == 200 && response.data != null) {
        return HomeSuggestion.fromJson(response.data);
      }
      return null;
    } catch (e) {
      debugPrint('ホーム画面の提案取得に失敗: $e');
      return null;
    }
  }

  Future<GraphData?> getAnalysisGraph() async {
    try {
      final response = await _dio.get('/api/analysis/graph');
      return GraphData.fromJson(response.data);
    } on DioException catch (e) {
      // 400 or 404 (Not Found) from backend means no data to generate graph.
      // We return null to let the UI handle this state gracefully.
      if (e.response?.statusCode == 400 || e.response?.statusCode == 404) {
        return null;
      }
      // For other errors, rethrow an exception.
      final errorMessage = e.response?.data?['error'] ?? 'グラフデータの取得に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      throw Exception('予期せぬエラーが発生しました: $e');
    }
  }


  Future<AnalysisSummary> getAnalysisSummary() async {
    try {
      final response = await _dio.get('/api/analysis/summary');
      return AnalysisSummary.fromJson(response.data);
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? '分析統計の取得に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      throw Exception('予期せぬエラーが発生しました: $e');
    }
  }

  Future<List<BookRecommendation>> getBookRecommendations() async {
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      _dio.options.receiveTimeout = const Duration(minutes: 2);
      final response = await _dio.get('/api/analysis/book_recommendations');
      final List<dynamic> data = response.data;
      return data.map((item) => BookRecommendation.fromJson(item)).toList();
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? '書籍の推薦取得に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      throw Exception('予期せぬエラーが発生しました: $e');
    } finally {
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }

  Future<NodeTapResponse?> getProactiveSuggestion() async {
    final originalConnectTimeout = _dio.options.connectTimeout;
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      _dio.options.connectTimeout = const Duration(minutes: 2);
      _dio.options.receiveTimeout = const Duration(minutes: 2);
      final response = await _dio.get('/api/analysis/proactive_suggestion');
      if (response.data == null) {
        return null;
      }
      return NodeTapResponse.fromJson(response.data);
    } on DioException catch (e) {
      debugPrint("--- DioException in getProactiveSuggestion ---");
      debugPrint("Response Data: ${e.response?.data}");
      debugPrint("---------------------------------------------");
      return null;
    } catch (e) {
      debugPrint("--- General Exception in getProactiveSuggestion ---");
      debugPrint(e.toString());
      debugPrint("-------------------------------------------------");
      return null;
    } finally {
      _dio.options.connectTimeout = originalConnectTimeout;
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }

  Future<ChatResponse> postChatMessage({
    required List<Map<String, String>> chatHistory,
    required String message,
    bool useRag = false,
    String? ragType,
  }) async {
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      _dio.options.receiveTimeout = const Duration(minutes: 5);
      final response = await _dio.post(
        '/api/analysis/chat',
        data: {
          'chat_history': chatHistory,
          'message': message,
          'use_rag': useRag,
          'rag_type': ragType,
        },
      );
      return ChatResponse.fromJson(response.data);
    } on DioException catch (e) {
      debugPrint("--- DioException in postChatMessage ---");
      debugPrint("Response: ${e.response?.data}");
      debugPrint("------------------------------------");
      if (e.type == DioExceptionType.receiveTimeout || e.type == DioExceptionType.connectionTimeout) {
           throw Exception('AIの応答時間が長すぎたため、タイムアウトしました。しばらくしてからもう一度お試しください。');
      }
      final errorMessage = e.response?.data?['error'] ?? 'メッセージの送信に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      debugPrint("--- General Exception in postChatMessage ---");
      debugPrint(e.toString());
      debugPrint("------------------------------------------");
      throw Exception('予期せぬエラーが発生しました: $e');
    } finally {
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }

  Future<NodeTapResponse> handleNodeTap(String nodeLabel) async {
    try {
      final response = await _dio.post(
        '/api/chat/node_tap',
        data: {'node_label': nodeLabel},
      );
      return NodeTapResponse.fromJson(response.data);
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? 'ノード情報の取得に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      throw Exception('予期せぬエラーが発生しました: $e');
    }
  }

  Future<Map<String, dynamic>> startSession(String topic) async {
    try {
      final response = await _dio.post(
        '/api/session/start',
        data: {'topic': topic},
      );
      return response.data;
    } on DioException catch (_) {
      throw Exception('セッションの開始に失敗しました。');
    }
  }

  Future<void> recordSwipe({
    required String sessionId,
    required String questionId,
    required bool answer,
    required double hesitationTime,
    required int swipeSpeed,
    required int turn,
  }) async {
    try {
      await _dio.post(
        '/api/session/$sessionId/swipe',
        data: {
          'question_id': questionId,
          'answer': answer,
          'hesitation_time': hesitationTime,
          'speed': swipeSpeed,
          'turn': turn,
        },
      );
    } on DioException catch (_) {
      throw Exception('回答の記録に失敗しました。');
    }
  }

  Future<void> postSummary({
    required String sessionId,
  }) async {
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      _dio.options.receiveTimeout = const Duration(minutes: 2);
      await _dio.post(
        '/api/session/$sessionId/summary',
      );
    } catch (e) {
      debugPrint('Failed to post summary request: $e');
    } finally {
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }

  Future<Map<String, dynamic>> continueSession({
    required String sessionId,
  }) async {
    try {
      final response = await _dio.post(
        '/api/session/$sessionId/continue',
      );
      return response.data;
    } on DioException catch (_) {
      throw Exception('セッションの継続に失敗しました。');
    }
  }
}