import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_service.dart';

// ApiService のインスタンスを提供するプロバイダ
final apiServiceProvider = Provider<ApiService>((ref) => ApiService());

// ユーザーからのリクエストを保持するプロバイダ (名前付きフィールドを持つレコード型に変更)
final apiRequestProvider = StateProvider<({String text, String? agentName})?>((ref) => null);

// API呼び出しと結果の取得を行うFutureProvider
final analyzeResultProvider = FutureProvider.autoDispose<AnalyzeResponse>((ref) async {
  final request = ref.watch(apiRequestProvider);

  if (request == null || request.text.isEmpty) { // フィールド名 'text' でアクセス
    throw Exception('Input text is empty or request is null.');
  }

  final apiService = ref.watch(apiServiceProvider);
  // レコードのフィールド名でアクセスして渡す
  return apiService.analyzeText(request.text, agentName: request.agentName);
});