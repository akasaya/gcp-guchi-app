import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
//import 'package:frontend/config/api_config.dart';

class ApiService {
  // ★★★ baseUrlを直接定義 ★★★
  // ローカルテスト時は 'http://127.0.0.1:8080' など、
  // デプロイ後はCloud RunのURLに書き換える
  final String _baseUrl = 'http://127.0.0.1:8080'; // ApiConfig.baseUrl;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Future<String?> _getIdToken() async {
    User? user = _auth.currentUser;
    if (user == null) {
      throw Exception('User not logged in');
    }
    return await user.getIdToken();
  }

  // ★★★ recordSwipeメソッドに hesitationTime を追加 ★★★
  Future<Map<String, dynamic>> recordSwipe({
    required String sessionId,
    required String questionId,
    required String answer,
    required double speed,
    required double hesitationTime, // この行を追加
  }) async {
    final token = await _getIdToken();
    final url = Uri.parse('$_baseUrl/session/$sessionId/swipe');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      // ★★★ body に hesitation_time を追加 ★★★
      body: jsonEncode({
        'question_id': questionId,
        'answer': answer,
        'speed': speed,
        'hesitation_time': hesitationTime, // この行を追加
        'user_id': _auth.currentUser!.uid,
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      print('Failed to record swipe: ${response.statusCode}');
      print('Response body: ${response.body}');
      throw Exception('Failed to record swipe');
    }
  }

  Future<Map<String, dynamic>> getSummary(String sessionId) async {
    final token = await _getIdToken();
    final userId = _auth.currentUser!.uid;
    // user_idをクエリパラメータとして追加
    final url = Uri.parse('$_baseUrl/session/$sessionId/summary?user_id=$userId');
    final response = await http.get(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      print('Failed to get summary: ${response.statusCode}');
      print('Response body: ${response.body}');
      throw Exception('Failed to get summary');
    }
  }

  // startSessionメソッドは変更なし
  Future<Map<String, dynamic>> startSession() async {
    final token = await _getIdToken();
    final url = Uri.parse('$_baseUrl/session/start');
    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'user_id': _auth.currentUser!.uid}),
    );

    if (response.statusCode == 201) {
      return jsonDecode(response.body);
    } else {
      print('Failed to start session: ${response.statusCode}');
      print('Response body: ${response.body}');
      throw Exception('Failed to start session');
    }
  }
}