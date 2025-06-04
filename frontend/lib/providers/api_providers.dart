import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/api_service.dart'; // 作成したApiServiceをインポート

// ApiServiceのインスタンスを提供するプロバイダ
// アプリケーション全体でApiServiceの同じインスタンスを共有できます。
final apiServiceProvider = Provider<ApiService>((ref) {
  return ApiService();
});

// APIに送信するテキストとエージェント名を保持するためのStateProvider
// これを更新することで、analyzeResultProviderが再実行されます。
final apiRequestProvider = StateProvider<({String text, String? agentName})?>((ref) => null);


// API呼び出しを行い、その結果 (AnalyzeResponse) またはエラーを非同期に提供するFutureProvider
// .family を使って、リクエスト内容（ここでは文字列のtext）を引数として受け取れるようにします。
// autoDispose をつけることで、このプロバイダが監視されなくなったら自動的に状態を破棄します。
final analyzeResultProvider = FutureProvider.autoDispose<AnalyzeResponse>((ref) async {
  final request = ref.watch(apiRequestProvider);
  if (request == null || request.text.isEmpty) {
    // リクエストがない、またはテキストが空の場合は、何もしないか、特定の初期状態を返す
    // ここではエラーを投げることで、UI側で適切にハンドリングできるようにします。
    // あるいは、nullを許容する型にして、UI側でnullチェックをする方法もあります。
    throw Exception('Input text is empty or request is not set.');
  }
  // apiServiceProviderからApiServiceのインスタンスを取得
  final apiService = ref.watch(apiServiceProvider);
  return await apiService.analyzeText(request.text, agentName: request.agentName);
});