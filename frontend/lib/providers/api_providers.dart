import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_service.dart'; // ApiService と AnalyzeResponse をインポート

// ApiService のインスタンスを提供するプロバイダ
final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

// ユーザーからのリクエスト（テキストとオプションのエージェント名）を保持するプロバイダ
final apiRequestProvider = StateProvider<(String text, String? agentName)?>( (ref) => null);

// API呼び出しと結果の取得を行うFutureProvider
final analyzeResultProvider = FutureProvider.autoDispose<AnalyzeResponse>((ref) async {
  final request = ref.watch(apiRequestProvider);

  if (request == null || request.text.isEmpty) {
    // 初期状態や入力が空の場合は、APIを呼び出さずにエラーまたは特定のレスポンスを返す
    // HomeScreen側でこの状態をハンドリングするので、ここではエラーを投げるのが一般的
    throw Exception('Input text is empty or request is null.');
  }

  // apiServiceProvider を使って ApiService のインスタンスを取得
  final apiService = ref.watch(apiServiceProvider);
  return apiService.analyzeText(request.text, agentName: request.agentName); // 名前付き引数で渡す
});