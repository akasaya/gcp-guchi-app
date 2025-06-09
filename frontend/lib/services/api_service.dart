import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';

class ApiService {
  // バックエンドのURL。Chromeでのデバッグの場合、通常はこちらで動作します。
  // もしAndroidエミュレータを使用している場合は 'http://10.0.2.2:8080' に変更してください。
  final String _baseUrl = 'http://127.0.0.1:8080';

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // ヘッダーを生成するプライベートメソッド
  Future<Map<String, String>> _getHeaders() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User not logged in');
    }
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  // セッションを開始する
  Future<Map<String, dynamic>> startSession(String topic) async {
    final url = Uri.parse('$_baseUrl/session/start');
    final headers = await _getHeaders();
    final response = await http.post(
      url,
      headers: headers,
      body: jsonEncode({'topic': topic}),
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to start session: ${response.body}');
    }
  }

  // スワイプを記録する
  Future<void> recordSwipe({
    required String sessionId,
    required String questionId,
    required String answer,
    required double hesitationTime,
    required int speed,
  }) async {
    final url = Uri.parse('$_baseUrl/session/$sessionId/swipe');
    final headers = await _getHeaders();
    final response = await http.post(
      url,
      headers: headers,
      body: jsonEncode({
        'question_id': questionId,
        'answer': answer,
        'hesitation_time': hesitationTime,
        'speed': speed,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to record swipe: ${response.body}');
    }
  }

  // セッションのサマリーを取得する
  Future<Map<String, dynamic>> getSummary(String sessionId) async {
    final url = Uri.parse('$_baseUrl/session/$sessionId/summary');
    final headers = await _getHeaders();
    final response = await http.get(url, headers: headers);

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } else {
      throw Exception('Failed to get summary: ${response.body}');
    }
  }

  // ★★★ 新しく追加したメソッド ★★★
  // セッションを継続する（深掘りする）
  Future<Map<String, dynamic>> continueSession({
    required String sessionId,
    required String summary,
    required String interactionAnalysis,
  }) async {
    final url = Uri.parse('$_baseUrl/session/$sessionId/continue');
    final headers = await _getHeaders();
    final response = await http.post(
      url,
      headers: headers,
      body: jsonEncode({
        'summary': summary,
        'interaction_analysis': interactionAnalysis,
      }),
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } else {
      final errorBody = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception('Failed to continue session: ${errorBody['error']}');
    }
  }
}