// ... existing code ...
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart'; // Firebase Authをインポート

class ApiService {
  final Dio _dio = Dio();
  static const String _baseUrl = 'http://127.0.0.1:8080'; // ローカル開発用

  // ヘルパーメソッドでログイン中のユーザーUIDを取得 (エラーハンドリングを強化しても良い)
  String? _getCurrentUserId() {
    return FirebaseAuth.instance.currentUser?.uid;
  }

  Future<Map<String, dynamic>> startSession() async {
    final userId = _getCurrentUserId();
    if (userId == null) {
      throw Exception('User not logged in. Cannot start session.');
    }

    try {
      final response = await _dio.post(
        '$_baseUrl/session/start',
        data: {
          'user_id': userId, // user_id を追加
        },
      );
      print('Session started (dio): ${response.data}');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      print('Error starting session (dio): $e');
      if (e.response != null && e.response?.data != null) {
        throw Exception('Failed to start session: ${e.response?.data}');
      }
      throw Exception('Failed to start session: ${e.message}');
    } catch (e) {
      print('Unknown error starting session: $e');
      throw Exception('An unknown error occurred: $e');
    }
  }

  // メソッド名とパラメータ名をバックエンドに合わせて変更
  Future<Map<String, dynamic>> recordSwipe({ // swipeSession から recordSwipe に変更し、パラメータを調整
    required String sessionId,
    required String questionId,
    required String answer, // 'direction' から 'answer' に変更
    required double speed,
  }) async {
    final userId = _getCurrentUserId();
    if (userId == null) {
      throw Exception('User not logged in. Cannot record swipe.');
    }

    try {
      final response = await _dio.post(
        '$_baseUrl/session/$sessionId/swipe',
        data: {
          'user_id': userId, // user_id を追加
          'question_id': questionId,
          'answer': answer, // 'direction' から 'answer' にキーを変更
          'speed': speed,
        },
      );
      print('Swipe successful (dio): ${response.data}');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      print('Error during swipe (dio): $e');
      if (e.response != null && e.response?.data != null) {
        throw Exception('Failed to swipe: ${e.response?.data}');
      }
      throw Exception('Failed to swipe: ${e.message}');
    } catch (e) {
      print('Unknown error during swipe: $e');
      throw Exception('An unknown error occurred during swipe: $e');
    }
  }

  Future<Map<String, dynamic>> getSessionSummary(String sessionId) async {
    final userId = _getCurrentUserId();
    if (userId == null) {
      throw Exception('User not logged in. Cannot get session summary.');
    }

    try {
      // user_id をクエリパラメータとして追加
      final response = await _dio.get('$_baseUrl/session/$sessionId/summary?user_id=$userId');
      print('Session summary fetched (dio): ${response.data}');
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      print('Error fetching session summary (dio): $e');
      if (e.response != null && e.response?.data != null) {
        throw Exception('Failed to fetch summary: ${e.response?.data}');
      }
      throw Exception('Failed to fetch summary: ${e.message}');
    } catch (e) {
      print('Unknown error fetching session summary: $e');
      throw Exception('An unknown error occurred fetching summary: $e');
    }
  }
}