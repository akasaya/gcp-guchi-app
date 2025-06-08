import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

class ApiService {
  final String _baseUrl = 'http://127.0.0.1:8080';
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Future<String> _getIdToken() async {
    User? user = _auth.currentUser;
    if (user == null) throw Exception('User not logged in');
    // トークンを強制的にリフレッシュして、有効なものを取得
    final token = await user.getIdToken(true);
    if (token == null) {
      throw Exception('IDトークンの取得に失敗しました。');
    }
    return token;
  }


  Future<Map<String, dynamic>> startSession({required String topic}) async {
    final token = await _getIdToken();
    final url = Uri.parse('$_baseUrl/session/start');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'topic': topic}),
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } else {
      final errorBody = utf8.decode(response.bodyBytes);
      print('Failed to start session: ${response.statusCode}');
      print('Response body: $errorBody');
      throw Exception('Failed to start session: ${response.statusCode}\n$errorBody');
    }
  }

  Future<void> recordSwipe({
    required String sessionId,
    required String questionId,
    required String answer,
    required double speed,
    required double hesitationTime,
  }) async {
    final token = await _getIdToken();
    final url = Uri.parse('$_baseUrl/session/$sessionId/swipe');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'question_id': questionId,
        'answer': answer,
        'speed': speed,
        'hesitation_time': hesitationTime,
      }),
    );

    if (response.statusCode != 200) {
      final errorBody = utf8.decode(response.bodyBytes);
      print('Failed to record swipe: ${response.statusCode}');
      print('Response body: $errorBody');
      throw Exception('Failed to record swipe');
    }
 }

  Future<Map<String, dynamic>> getSummary(String sessionId) async {
    final token = await _getIdToken();

    final url = Uri.parse('$_baseUrl/session/$sessionId/summary');
    
    final response = await http.get(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } else {
      final errorBody = utf8.decode(response.bodyBytes);
      print('Failed to get summary: ${response.statusCode}');
      print('Response body: $errorBody');
      throw Exception('Failed to get summary: ${response.statusCode}\n$errorBody');
    }
  }
}