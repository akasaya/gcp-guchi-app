import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ApiService {
  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:8080', // TODO: Replace with your actual backend URL
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  ));
  final _auth = FirebaseAuth.instance;

  Future<String?> _getIdToken() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User not logged in');
    }
    return await user.getIdToken();
  }

  Future<Map<String, dynamic>> startSession(String topic) async {
    final token = await _getIdToken();
    final response = await _dio.post(
      '/session/start',
      data: jsonEncode({'topic': topic}),
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    return response.data;
  }

  Future<void> recordSwipe({
    required String sessionId,
    required String questionId,
    required String answer,
    required double hesitationTime,
    required int swipeSpeed,
    required int turn, // turnを追加
  }) async {
    final token = await _getIdToken();
    await _dio.post(
      '/session/$sessionId/swipe',
      data: jsonEncode({
        'question_id': questionId,
        'answer': answer,
        'hesitation_time': hesitationTime,
        'speed': swipeSpeed,
        'turn': turn, // turnを送信
      }),
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }

  // getSummaryをpostSummaryに変更し、引数をswipesにする
  Future<Map<String, dynamic>> postSummary({
    required String sessionId,
    required List<Map<String, dynamic>> swipes,
  }) async {
    final token = await _getIdToken();
    final response = await _dio.post(
      '/session/$sessionId/summary',
      data: jsonEncode({'swipes': swipes}), // 送信するデータをswipesに変更
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    return response.data;
  }

  Future<Map<String, dynamic>> continueSession({
    required String sessionId,
    required String insights,
  }) async {
    final token = await _getIdToken();
    final response = await _dio.post(
      '/session/$sessionId/continue',
      data: jsonEncode({'insights': insights}),
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
    return response.data;
  }
}