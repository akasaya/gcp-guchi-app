import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart'; // main.dart をインポート (MyAppのため)
import 'package:frontend/providers/api_providers.dart'; // プロバイダをインポート
import 'package:frontend/services/api_service.dart'; // AnalyzeResponseのため (モックで使用)
// import 'package:frontend/screens/home_screen.dart'; // HomeScreen を直接テストする場合はこちらも

// ApiServiceのモックを作成 (オプションですが、より堅牢なテストになります)
class MockApiService extends ApiService {
  // 必要に応じて analyzeText の挙動をここで定義
  @override
  Future<AnalyzeResponse> analyzeText(String text, String? agentName) async {
    if (text == "error") {
      throw Exception("Mock API Error");
    }
    if (text.isEmpty) { // api_service.dart のロジックに合わせるか、プロバイダ側で制御
      // このテストではプロバイダ側で制御するため、ここでは正常なレスポンスを返す
      return AnalyzeResponse(results: 'Mocked response for empty text');
    }
    return AnalyzeResponse(results: 'Mocked API Response for "$text"');
  }
}


void main() {
  testWidgets('HomeScreen 初期表示の確認', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MyApp(), // MyApp経由でHomeScreenをテスト
      ),
    );

    // AppBarのタイトル
    expect(find.text('愚痴アプリ'), findsOneWidget);

    // 主要なテキスト
    expect(find.text('今日の愚痴をどうぞ:'), findsOneWidget);
    expect(find.text('分析結果:'), findsOneWidget);

    // テキスト入力フィールド
    expect(find.byType(TextField), findsOneWidget);

    // ボタン
    expect(find.widgetWithText(ElevatedButton, '分析する'), findsOneWidget);

    // 初期状態の分析結果エリアのテキスト
    // apiRequestProvider が null の場合は "入力して分析ボタンを押してください。" が表示される
    expect(find.text('入力して分析ボタンを押してください。'), findsOneWidget);
  });

  testWidgets('テキスト入力と分析ボタン押下 - 成功時', (WidgetTester tester) async {
    // apiServiceProvider をモックでオーバーライド
    final mockApiService = MockApiService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // apiServiceProvider をモックインスタンスでオーバーライド
          // ただし、現状の api_providers.dart は apiService直接ではなく、
          // analyzeResultProvider が apiRequestProvider を watch し、
          // apiRequestProvider.notifier.state の更新をトリガーに Future を実行する形になっている。
          // そのため、analyzeResultProvider 自体をモックするか、
          // apiRequestProvider に値をセットして、analyzeResultProvider の動作を期待する形になる。
          // ここでは、より実際の動作に近い形で、apiRequestProvider を操作し、
          // analyzeResultProvider が (モックされた) APIの結果を表示することを期待する。
          // そのためには、ApiService自体がモックされている必要があるが、
          // api_providers.dart の中で ApiService が直接 new されているため、
          // Provider自体を差し替えるか、ApiService をDIできるようにリファクタリングが必要。

          // 簡単のため、ここでは analyzeResultProvider を直接オーバーライドして状態を模倣します。
          // より良い方法は、apiServiceProvider を用意してそれをオーバーライドすることです。
          apiRequestProvider.overrideWith((ref) => null), // 初期状態
          analyzeResultProvider.overrideWith(
            (ref) async {
              final request = ref.watch(apiRequestProvider);
              if (request == null || request.text.isEmpty) {
                // この分岐はテストケースによって調整
                return AnalyzeResponse(results: '入力してください');
              }
              if (request.text == "error_case") {
                 throw Exception("Simulated API Error");
              }
              // 実際のAPI呼び出しの代わりにモックされたレスポンスを返す
              return AnalyzeResponse(results: 'サーバーからの成功レスポンス: ${request.text}');
            }
          )
        ],
        child: const MyApp(),
      ),
    );

    // テキストを入力
    await tester.enterText(find.byType(TextField), 'テストの愚痴');
    await tester.pump(); // pumpしてUIを更新

    // ボタンを押す
    // _analyzeGuchiメソッド内でapiRequestProvider.notifier.stateを更新する
    await tester.tap(find.widgetWithText(ElevatedButton, '分析する'));
    
    // --- ローディング状態の確認 ---
    // analyzeResultProvider が非同期処理を開始すると、loading状態になるはず。
    // pumpして非同期処理の開始を検知させる
    await tester.pump(); // FutureProviderがlistenを開始するのを待つ
    expect(find.byType(CircularProgressIndicator), findsOneWidget); // ローディング表示
    
    // 非同期処理の完了を待つ (十分な時間 pump するか、pumpAndSettle を使用)
    await tester.pumpAndSettle();

    // 結果が表示されることを確認
    expect(find.text('サーバーからの成功レスポンス: テストの愚痴'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing); // ローディングが消えていること
  });


  testWidgets('テキスト入力と分析ボタン押下 - APIエラー時', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // analyzeResultProvider をエラーを返すようにオーバーライド
          analyzeResultProvider.overrideWithProvider(
            FutureProvider.autoDispose((ref) async {
              final request = ref.watch(apiRequestProvider);
              if (request != null && request.text == "error_trigger") {
                throw Exception('テスト用のAPIエラー');
              }
              // 他のケースでは成功レスポンスまたは初期状態
              if (request == null || request.text.isEmpty) {
                return AnalyzeResponse(results: '入力してください');
              }
              return AnalyzeResponse(results: '成功レスポンス');
            })
          ),
        ],
        child: const MyApp(),
      ),
    );

    // エラーをトリガーするテキストを入力
    await tester.enterText(find.byType(TextField), 'error_trigger');
    await tester.pump();

    // ボタンを押す
    await tester.tap(find.widgetWithText(ElevatedButton, '分析する'));
    await tester.pump(); // ローディング表示のため

    // ローディング表示
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle(); // 非同期処理完了を待つ

    // エラーメッセージが表示されることを確認
    expect(find.textContaining('エラーが発生しました:'), findsOneWidget);
    expect(find.textContaining('テスト用のAPIエラー'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('テキスト未入力で分析ボタン押下', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MyApp(),
      ),
    );

    // 分析ボタンを押す
    await tester.tap(find.widgetWithText(ElevatedButton, '分析する'));
    await tester.pumpAndSettle(); // SnackBarが表示されるのを待つ

    // SnackBarが表示されることを確認 (SnackBarのテストはfindsOneWidgetでは難しい場合がある)
    // ここでは、分析結果エリアのテキストが変わらない（または初期メッセージのまま）ことを確認する方が確実かもしれません。
    expect(find.text('愚痴を入力してください。'), findsOneWidget); // SnackBarのテキスト
    // または、分析結果エリアが初期状態のままであることを確認
    expect(find.text('入力して分析ボタンを押してください。'), findsOneWidget);
  });
}