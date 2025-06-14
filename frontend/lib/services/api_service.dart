import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/graph_data.dart';
import 'dart:convert'; // dart:convertをインポート

// ApiServiceをアプリケーション全体で利用可能にするためのProvider
final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

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
            print("Error getting ID token: $e");
            return handler.reject(DioException(requestOptions: options, error: e));
          }
        }
        return handler.next(options);
      },
      onError: (DioException e, handler) {
        print("Dio Error: ${e.response?.statusCode} - ${e.message}");
        return handler.next(e);
      },
    ));
  }

  /// ★★★ ここから下が各APIを呼び出すメソッド群です ★★★

  /// 【新規追加】統合分析グラフのデータを取得する
  Future<GraphData> getAnalysisGraph() async {
    // 現在のタイムアウト設定を一時的に保存します
    final originalConnectTimeout = _dio.options.connectTimeout;
    final originalReceiveTimeout = _dio.options.receiveTimeout;

    try {
      // このリクエストのために、タイムアウトを2分に延長します
      _dio.options.connectTimeout = const Duration(minutes: 2);
      _dio.options.receiveTimeout = const Duration(minutes: 2);

      // 安定している .get() メソッドでリクエストを実行します
      final response = await _dio.get('/analysis/graph');

      // ★★★【根本原因の修正】★★★
      // response.dataが標準的なJSON Mapではない可能性があるため、
      // 一度JSON文字列に変換し、再度デコードすることで、
      // 確実に Map<String, dynamic> 形式に変換します。
      final responseBody = response.data;
      final Map<String, dynamic> jsonMap;
      if (responseBody is Map) {
        jsonMap = json.decode(json.encode(responseBody)) as Map<String, dynamic>;
      } else if (responseBody is String) {
        jsonMap = json.decode(responseBody) as Map<String, dynamic>;
      } else {
        throw Exception('Received unexpected data format from server');
      }
      return GraphData.fromJson(response.data);
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? '分析データの取得に失敗しました。';
      print(
          'Error fetching graph data: $errorMessage, Details: ${e.response?.data?['details']}');
      throw Exception(errorMessage);
    } catch (e) {
      print('An unexpected error occurred while fetching graph data: $e');
      throw Exception('予期せぬエラーが発生しました。');
    } finally {
      // 通信が成功しても失敗しても、必ず元の設定に戻します
      _dio.options.connectTimeout = originalConnectTimeout;
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }

    /// 【新規追加】チャットメッセージを送信し、AIの応答を取得する
  Future<String> postChatMessage({
    required List<Map<String, String>> chatHistory,
    required String message,
  }) async {
    try {
      final response = await _dio.post(
        '/analysis/chat',
        data: {
          'chat_history': chatHistory,
          'message': message,
        },
      );
      return response.data['response'];
    } on DioException catch (e) {
      final errorMessage = e.response?.data?['error'] ?? 'メッセージの送信に失敗しました。';
      print(
          'Error posting chat message: $errorMessage, Details: ${e.response?.data?['details']}');
      throw Exception(errorMessage);
    } catch (e) {
      print('An unexpected error occurred while posting chat message: $e');
      throw Exception('予期せぬエラーが発生しました。');
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
    } on DioException catch (e) {
      print("Error starting session: ${e.message}");
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
    } on DioException catch (e) {
      print("Error recording swipe: ${e.message}");
      throw Exception('回答の記録に失敗しました。');
    }
  }

  /// ターン終了時に回答をまとめて送信し、分析結果を取得する
  Future<Map<String, dynamic>> postSummary({
    required String sessionId,
    required List<Map<String, dynamic>> swipes,
  }) async {
    try {
      // ★★★ フロントエンド側でデータを整形してから送信する ★★★
      final formattedSwipes = swipes.map((swipe) {
        return {
          'question_text': swipe['question_text'],
          'answer': swipe['answer'], // bool値
          'hesitation_time': swipe['hesitation_time'],
        };
      }).toList();

      final response = await _dio.post(
        '/session/$sessionId/summary',
        data: {'swipes': formattedSwipes}, // ★★★ 整形後のデータを送信 ★★★
      );
      return response.data;
    } on DioException catch (e) {
      print("Error posting summary: ${e.message}");
      throw Exception('分析結果の取得に失敗しました。');
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
    } on DioException catch (e) {
      print("Error continuing session: ${e.message}");
      throw Exception('セッションの継続に失敗しました。');
    }
  }
}