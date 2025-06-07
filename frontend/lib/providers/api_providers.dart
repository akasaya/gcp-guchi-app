// ... existing code ...
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart'; // Dioをインポート
import '../services/api_service.dart';

// Dio のインスタンスを提供するプロバイダ
final dioProvider = Provider<Dio>((ref) => Dio());

// ApiService のインスタンスを提供するプロバイダ
final apiServiceProvider = Provider<ApiService>((ref) {
  // dioProvider から Dio インスタンスを取得
  final dio = ref.watch(dioProvider);
  // ApiService のコンストラクタに Dio インスタンスを渡す
  return ApiService(dio);
});

// ユーザーからのリクエストを保持するプロバイダ (変更なし)
final apiRequestProvider = StateProvider<({String text, String? agentName})?>((ref) => null);

// API呼び出しと結果の取得を行うFutureProvider (変更なし)
final analyzeResultProvider = FutureProvider.autoDispose<MultiAgentAnalyzeResponse>((ref) async {
  final request = ref.watch(apiRequestProvider);

  if (request == null || request.text.isEmpty) {
    throw Exception('Input text is empty or request is null.');
  }

  final apiService = ref.watch(apiServiceProvider);
  return apiService.analyzeText(request.text);
});