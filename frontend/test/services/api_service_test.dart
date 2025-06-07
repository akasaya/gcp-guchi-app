import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:dio/dio.dart';

// ApiService とレスポンスモデルをインポート
// パスは実際のプロジェクト構造に合わせて調整してください
import 'package:frontend/services/api_service.dart';

// Mockito で Dio のモッククラスを生成するためのアノテーション
// ファイル名を指定 (例: api_service_test.mocks.dart)
@GenerateMocks([Dio], customMocks: [
  MockSpec<Response<dynamic>>(as: #MockResponse),
])
import 'api_service_test.mocks.dart'; // 生成されるモックファイル

void main() {
  late ApiService apiService;
  late MockDio mockDio; // MockDioのインスタンスを保持

  setUp(() {
    mockDio = MockDio();
    // リファクタリングされたApiServiceにmockDioを注入
    apiService = ApiService(mockDio);
  });

  group('ApiService Tests', () {
    const testText = 'This is a test guchi.';
    // APIのベースURLとエンドポイント（api_service.dartの実装に合わせる）
    // String.fromEnvironment から取得しているため、テスト時はデフォルト値が使われる想定
    final analyzeEndpoint = 'https://guchi-gateway-1036638910637.us-central1.run.app/analyze';

    // 成功時のレスポンスのダミーデータ
    final mockSuccessResponseData = {
      "agent_a_response": {
        "empathy_message": "That sounds tough.",
        "category": "work",
        "keywords": ["test", "guchi"],
        "error": null
      },
      "agent_b_response": {
        "identified_problem": "Too much testing.",
        "solution_ideas": ["Take a break"],
        "positive_perspective": "Tests make code robust.",
        "error": null
      },
      "agent_c_response": {
        "helpful_information": [{"title": "How to test", "summary": "Just do it."}],
        "similar_case_example": "Everyone tests.",
        "error": null
      }
    };

    test('analyzeText returns MultiAgentAnalyzeResponse on successful API call', () async {
      // モックDioのpostメソッドが呼ばれたときの動作を設定
      when(mockDio.post(
        analyzeEndpoint, // 修正されたエンドポイントを使用
        data: {'text': testText},
      )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: analyzeEndpoint),
            data: mockSuccessResponseData,
            statusCode: 200,
          ));

      // テスト対象メソッドの実行
      final result = await apiService.analyzeText(testText);

      // 結果の検証
      expect(result, isA<MultiAgentAnalyzeResponse>());
      expect(result.overallError, isNull);
      expect(result.agentAResponse, isNotNull);
      expect(result.agentAResponse?.empathyMessage, "That sounds tough.");
      expect(result.agentAResponse?.error, isNull);
      expect(result.agentBResponse?.solutionIdeas?.first, "Take a break");
      expect(result.agentBResponse?.error, isNull);
      expect(result.agentCResponse?.helpfulInformation?.first.title, "How to test");
      expect(result.agentCResponse?.error, isNull);


      // 呼び出し検証 (オプション)
      verify(mockDio.post(analyzeEndpoint, data: {'text': testText})).called(1);
    });

    test('analyzeText handles DioException with response body', () async {
      final dioException = DioException(
        requestOptions: RequestOptions(path: analyzeEndpoint),
        response: Response(
          requestOptions: RequestOptions(path: analyzeEndpoint),
          data: {'error': 'Simulated Dio Error from response body'},
          statusCode: 500,
        ),
        message: 'Simulated Dio Error message part', // message プロパティを使用 (以前は error だったが dio v5 では message)
        type: DioExceptionType.badResponse,
      );

      when(mockDio.post(
        analyzeEndpoint,
        data: {'text': testText},
      )).thenThrow(dioException);

      final result = await apiService.analyzeText(testText);

      expect(result, isA<MultiAgentAnalyzeResponse>());
      expect(result.overallError, isNotNull);
      // api_service.dart の修正後のエラーメッセージ形式に合わせる
      expect(result.overallError, contains('Failed to analyze text (DioError Type: DioExceptionType.badResponse): Simulated Dio Error message part'));
      expect(result.overallError, contains('Status Code: 500'));
      expect(result.overallError, contains('Response Data: {error: Simulated Dio Error from response body}'));
    });
    
    test('analyzeText handles DioException without response body', () async {
      final dioException = DioException(
        requestOptions: RequestOptions(path: analyzeEndpoint),
        // response: null, // response がない場合
        message: 'Simulated Dio Error without response', // message に設定
        type: DioExceptionType.connectionTimeout,
      );

      when(mockDio.post(
        analyzeEndpoint,
        data: {'text': testText},
      )).thenThrow(dioException);
      
      final result = await apiService.analyzeText(testText);

      expect(result, isA<MultiAgentAnalyzeResponse>());
      expect(result.overallError, isNotNull);
      // api_service.dart の修正後のエラーメッセージ形式に合わせる
      expect(result.overallError, contains('Failed to analyze text (DioError Type: DioExceptionType.connectionTimeout): Simulated Dio Error without response'));
      expect(result.overallError, contains('Error sending request or no response data.')); // response がないのでこの部分も含まれる
      expect(result.overallError, isNot(contains('Status Code:'))); 
    });


    test('analyzeText handles non-200 status code with error body from API', () async {
        when(mockDio.post(
            analyzeEndpoint,
            data: {'text': testText},
        )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: analyzeEndpoint),
            data: {'error': 'Backend validation failed', 'details': 'Text too short'}, // この 'error' の値が使われる
            statusCode: 400, // 例: Bad Request
        ));
        
        final result = await apiService.analyzeText(testText);
        
        expect(result, isA<MultiAgentAnalyzeResponse>());
        expect(result.overallError, isNotNull); // 修正により null でなくなるはず
        // MultiAgentAnalyzeResponse.fromJson は json['error'] を overallError に設定するので、
        // 'Backend validation failed' が overallError になる。
        expect(result.overallError, equals('Backend validation failed')); 
        // ApiServiceの putIfAbsent は元の 'error' があるため、HTTP Status等は追加しない。
    });

     test('analyzeText handles API returning unexpected (non-JSON string) in data field for 200 status', () async {
        when(mockDio.post(
            analyzeEndpoint,
            data: {'text': testText},
        )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: analyzeEndpoint),
            data: "This is not a JSON string",
            statusCode: 200,
        ));
        
        final result = await apiService.analyzeText(testText);
        
        expect(result, isA<MultiAgentAnalyzeResponse>());
        expect(result.overallError, isNotNull);
        expect(result.overallError, contains('FormatException')); // FormatException が含まれることを確認
        expect(result.overallError, contains('This is not a JSON string')); // 元の文字列も含まれる
    });

    test('analyzeText handles API returning valid JSON but missing agent keys', () async {
        when(mockDio.post(
            analyzeEndpoint,
            data: {'text': testText},
        )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: analyzeEndpoint),
            // agent_a_response などが欠けているJSON
            data: {"some_other_key": "some_value"}, 
            statusCode: 200,
        ));
        
        final result = await apiService.analyzeText(testText);
        
        expect(result, isA<MultiAgentAnalyzeResponse>());
        expect(result.overallError, isNull); // API自体は成功(200)なので全体エラーはない
        expect(result.agentAResponse, isNotNull);
        expect(result.agentAResponse?.error, equals("Agent A response missing")); // FromJson のフォールバック
        expect(result.agentBResponse, isNotNull);
        expect(result.agentBResponse?.error, equals("Agent B response missing"));
        expect(result.agentCResponse, isNotNull);
        expect(result.agentCResponse?.error, equals("Agent C response missing"));
    });
  });
}