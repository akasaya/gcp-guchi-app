import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/graph_data.dart';


// ApiServiceをアプリケーション全体で利用可能にするためのProvider
final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

class ChatResponse {
  final String answer;
  final List<String> sources;

  ChatResponse({required this.answer, required this.sources});

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    return ChatResponse(
      answer: json['answer'] as String,
      sources: (json['sources'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

class ApiService {
  final Dio _dio = Dio();
  final FirebaseAuth _auth = FirebaseAuth.instance;

  ApiService() {
    // --- ベースURLとタイムアウト設定 ---
    // お手元のコードにあった本番URLを反映しています
    const String prodBaseUrl = "https://kokoro-himotoku-api-877175644081.asia-northeast1.run.app"; 

    final String baseUrl = (kDebugMode && defaultTargetPlatform == TargetPlatform.android)
        ? 'http://10.0.2.2:8080' // Androidエミュレータ
        : (kDebugMode)
            ? 'http://localhost:8080' // iOSシミュレータ、Web、デスクトップ
            : prodBaseUrl; // 本番環境

    _dio.options.baseUrl = baseUrl;
    _dio.options.connectTimeout = const Duration(seconds: 15);
    _dio.options.receiveTimeout = const Duration(seconds: 30); // AIの応答時間を考慮

    // --- Interceptorによる認証トークンの自動付与 ---
    // この設定により、今後この_dioインスタンスを使うリクエストには
    // 自動で認証ヘッダーが付与されるため、各メソッドでの手動設定が不要になります。
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        final user = _auth.currentUser;
        if (user != null) {
          try {
            final token = await user.getIdToken(true); // トークンを強制リフレッシュ
            options.headers['Authorization'] = 'Bearer $token';
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

  /// ★★★ ここから下が各APIを呼び出すメソッド群です ★★★

  /// 【新規追加】統合分析グラフのデータを取得する
  Future<GraphData> getAnalysisGraph() async {
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      // グラフ生成は時間がかかるため、このリクエストのタイムアウトを2分に延長
      _dio.options.receiveTimeout = const Duration(minutes: 2);
      final response = await _dio.get('/analysis/graph');
      return GraphData.fromJson(response.data);
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? '分析データの取得に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      throw Exception('予期せぬエラーが発生しました。');
    } finally {
      // タイムアウト設定を元に戻す
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }


    /// 【新規追加】チャットメッセージを送信し、AIの応答を取得する
  Future<ChatResponse> postChatMessage({
    required List<Map<String, String>> chatHistory,
    required String message,
    bool useRag = false, // RAG機能を使うかどうかのフラグを追加
  }) async {
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      _dio.options.receiveTimeout = const Duration(minutes: 2);
      final response = await _dio.post(
        '/analysis/chat',
        data: {
          'chat_history': chatHistory,
          'message': message,
          'use_rag': useRag, // フラグをAPIに送信
        },
      );
      // 新しいChatResponseクラスとして結果を返すように変更
      return ChatResponse.fromJson(response.data);
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? 'メッセージの送信に失敗しました。';
      throw Exception(errorMessage);
    } catch (e) {
      throw Exception('予期せぬエラーが発生しました。');
    } finally {
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }


  /// セッションを開始する
  Future<Map<String, dynamic>> startSession(String topic) async {
    try {
      // Interceptorが認証を行うため、ヘッダー指定は不要
      // DioがMapを自動でJSONに変換するため、jsonEncodeは不要
      final response = await _dio.post(
        '/session/start',
        data: {'topic': topic},
      );
      return response.data;
    } on DioException catch (_) {
      throw Exception('セッションの開始に失敗しました。');
    }
  }

  /// スワイプを記録する
  Future<void> recordSwipe({
    required String sessionId,
    required String questionId,
    required bool answer, // ★★★ Stringからboolに変更 ★★★
    required double hesitationTime,
    required int swipeSpeed,
    required int turn,
  }) async {
    try {
      await _dio.post(
        '/session/$sessionId/swipe',
        data: {
          'question_id': questionId,
          'answer': answer, // bool値をそのまま送信
          'hesitation_time': hesitationTime,
          'speed': swipeSpeed,
          'turn': turn,
        },
      );
    } on DioException catch (_) {
      throw Exception('回答の記録に失敗しました。');
    }
  }

  /// ターン終了時に回答をまとめて送信し、分析結果を取得する
  Future<Map<String, dynamic>> postSummary({
    required String sessionId,
    required List<Map<String, dynamic>> swipes,
  }) async {
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      final formattedSwipes = swipes.map((swipe) {
        return {
          'question_text': swipe['question_text'],
          'answer': swipe['answer'],
          'hesitation_time': swipe['hesitation_time'],
        };
      }).toList();

      // AIの分析は時間がかかるため、このリクエストのタイムアウトを2分に延長
      _dio.options.receiveTimeout = const Duration(minutes: 2);
      final response = await _dio.post(
        '/session/$sessionId/summary',
        data: {'swipes': formattedSwipes},
      );
      return response.data;
    } on DioException catch (_) {
      throw Exception('分析結果の取得に失敗しました。');
    } finally {
      // タイムアウト設定を元に戻す
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }


  /// 次のターンに進む
  Future<Map<String, dynamic>> continueSession({
    required String sessionId,
    required String insights,
  }) async {
    try {
      final response = await _dio.post(
        '/session/$sessionId/continue',
        data: {'insights': insights},
      );
      return response.data;
    } on DioException catch (_) {
      throw Exception('セッションの継続に失敗しました。');
    }
  }
}