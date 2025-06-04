import 'package:dio/dio.dart';

// AnalyzeResponseクラスをファイルの先頭、またはApiServiceクラスの前に定義
class AnalyzeResponse {
  final String results;

  AnalyzeResponse({required this.results});

  factory AnalyzeResponse.fromJson(Map<String, dynamic> json) {
    // 'results' キーが存在しない場合やnullの場合のフォールバックを追加するとより堅牢になります
    return AnalyzeResponse(results: json['results'] as String? ?? ''); // nullなら空文字
  }
}

class ApiService {
  final Dio _dio = Dio();
  // TODO: あなたのCloud RunサービスのURLに置き換えてください
  static const String _baseUrl = "https://guchi-gateway-1036638910637.us-central1.run.app";

  Future<AnalyzeResponse> analyzeText(String text, {String? agentName}) async {
    final Map<String, dynamic> requestBody = {'text': text};
    if (agentName != null) {
      requestBody['agent_name'] = agentName;
    }

    try {
      // dioのレスポンスを変数に格納
      final Response response = await _dio.post( // Response型を明示
        "$_baseUrl/analyze",
        data: requestBody,
      );

      if (response.statusCode == 200 && response.data != null) {
        // response.data が null でないことも確認
        return AnalyzeResponse.fromJson(response.data as Map<String, dynamic>);
      } else {
        // レスポンスコードやデータが期待通りでない場合のエラー
        throw Exception('Failed to analyze text: Status Code ${response.statusCode}, Data: ${response.data}');
      }
    } on DioException catch (e) {
      // DioExceptionのハンドリングをより詳細に
      String errorMessage = 'Failed to analyze text (DioError): ${e.message}';
      if (e.response != null) {
        errorMessage += '\nStatus Code: ${e.response?.statusCode}';
        errorMessage += '\nResponse Data: ${e.response?.data}';
      } else {
        errorMessage += '\nError sending request: ${e.message}';
      }
      // print('DioError: $errorMessage');
      throw Exception(errorMessage);
    } catch (e) {
      // その他の予期せぬエラー
      // print('Unknown Error in analyzeText: $e');
      throw Exception('Failed to analyze text (Unknown Error): $e');
    }
  }
}