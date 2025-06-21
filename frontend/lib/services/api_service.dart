import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/graph_data.dart';
import '../models/chat_models.dart'; 


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

    // ★★★ このメソッドを新規追加 ★★★
  Future<HomeSuggestion?> getHomeSuggestionV2() async {
    try {
      final response = await _dio.get('/home/suggestion_v2');
      // 204 No Content の場合は data が null になる
      if (response.statusCode == 200 && response.data != null) {
        return HomeSuggestion.fromJson(response.data);
      }
      return null; // 204 やその他のステータスコードの場合は null
    } catch (e) {
      // ホーム画面の提案は表示されなくてもクリティカルではないため、エラーは握りつぶす
      debugPrint('ホーム画面の提案(v2)取得に失敗: $e');
      return null;
    }
  }

    Future<HomeSuggestion?> getHomeSuggestion() async {
    try {
      final response = await _dio.get('/home/suggestion');
      if (response.statusCode == 200 && response.data != null) {
        return HomeSuggestion.fromJson(response.data);
      }
      return null;
    } catch (e) {
      // ホーム画面の提案は表示されなくてもクリティカルではないため、エラーは握りつぶす
      debugPrint('ホーム画面の提案取得に失敗: $e');
      return null;
    }
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

  // ★★★ この関数を修正（デバッグ用のログを強化） ★★★
  Future<NodeTapResponse?> getProactiveSuggestion() async {
    // このAPIは複数のAI呼び出しを含むため、特別にタイムアウトを延長します
    final originalConnectTimeout = _dio.options.connectTimeout;
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      _dio.options.connectTimeout = const Duration(minutes: 2);
      _dio.options.receiveTimeout = const Duration(minutes: 2);

      final response = await _dio.get('/analysis/proactive_suggestion');
      if (response.data == null) {
        return null; // 提案がない場合はnullを返す
      }
      return NodeTapResponse.fromJson(response.data);
    } on DioException catch (e) {
      // 提案の取得は失敗しても致命的ではないので、エラーは投げずにコンソールに出力するだけ
      debugPrint("--- DioException in getProactiveSuggestion ---");
      debugPrint("Type: ${e.type}");
      debugPrint("Message: ${e.message}");
      debugPrint("Response Status: ${e.response?.statusCode}");
      debugPrint("Response Data: ${e.response?.data}");
      debugPrint("---------------------------------------------");
      return null;
    } catch (e) {
      debugPrint("--- General Exception in getProactiveSuggestion ---");
      debugPrint(e.toString());
      debugPrint("-------------------------------------------------");
      return null;
    } finally {
      // タイムアウト設定を元に戻します
      _dio.options.connectTimeout = originalConnectTimeout;
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }



    /// 【新規追加】チャットメッセージを送信し、AIの応答を取得する
    Future<ChatResponse> postChatMessage({
      required List<Map<String, String>> chatHistory,
      required String message,
      bool useRag = false,
      String? ragType, // ★★★ RAGの種別を指定するパラメータを追加 ★★★
    }) async {
      final originalReceiveTimeout = _dio.options.receiveTimeout;
      try {
        _dio.options.receiveTimeout = const Duration(minutes: 5);
        final response = await _dio.post(
          '/analysis/chat',
          data: {
            'chat_history': chatHistory,
            'message': message,
            'use_rag': useRag,
            'rag_type': ragType, // ★★★ APIに送信 ★★★
          },
        );
        return ChatResponse.fromJson(response.data);
      } on DioException catch (e) {
        // エラーハンドリングを詳細化し、コンソールで原因を追いやすくします
        debugPrint("--- DioException in postChatMessage ---");
        debugPrint("Type: ${e.type}");
        debugPrint("Message: ${e.message}");
        debugPrint("Response: ${e.response?.data}");
        debugPrint("------------------------------------");

        // タイムアウトの場合、より分かりやすいメッセージを出すようにします
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

      // ★★★ 新規追加: ノードタップ時の処理を呼び出すメソッド ★★★
  Future<NodeTapResponse> handleNodeTap(String nodeLabel) async {
    try {
      final response = await _dio.post(
        '/chat/node_tap',
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
  Future<void> postSummary({
    required String sessionId,
  }) async {
    final originalReceiveTimeout = _dio.options.receiveTimeout;
    try {
      // AIの分析は時間がかかるため、このリクエストのタイムアウトを2分に延長
      _dio.options.receiveTimeout = const Duration(minutes: 2);
      await _dio.post(
        '/session/$sessionId/summary',
      );
    } catch (e) {
      // fire-and-forgetなので、アプリをクラッシュさせずにエラーを記録するだけ
      debugPrint('Failed to post summary request: $e');
    } finally {
      // タイムアウト設定を元に戻す
      _dio.options.receiveTimeout = originalReceiveTimeout;
    }
  }


  /// 次のターンに進む
  Future<Map<String, dynamic>> continueSession({
    required String sessionId,
  }) async {
    try {
      final response = await _dio.post(
        '/session/$sessionId/continue',
      );
      return response.data;
    } on DioException catch (_) {
      throw Exception('セッションの継続に失敗しました。');
    }
  }
}