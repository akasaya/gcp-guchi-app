import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/providers/api_providers.dart';
import 'package:frontend/services/api_service.dart';

// ApiServiceのモック
class MockApiService extends ApiService {
  @override
  Future<AnalyzeResponse> analyzeText(String text, {String? agentName}) async { // 名前付き引数に修正
    if (text == "error_case") { // テストケースでエラーを発生させるためのキーワード
      throw Exception('Mock API Error');
    }
    if (text.isEmpty) {
      return AnalyzeResponse(results: 'Mocked response for empty text from API');
    }
    return AnalyzeResponse(results: 'Mocked API Response for "$text" with agent "${agentName ?? 'default'}"');
  }
}

void main() {
  testWidgets('HomeScreen 初期表示の確認', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MyApp(),
      ),
    );
    expect(find.text('愚痴アプリ'), findsOneWidget);
    expect(find.text('今日の愚痴をどうぞ:'), findsOneWidget);
    expect(find.text('分析結果:'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '分析する'), findsOneWidget);
    // analyzeResultProvider の初期状態はエラー (Input text is empty...) になるか、
    // HomeScreen側でリクエストがnullの場合の表示ハンドリングに依存する
    // ここでは、HomeScreenがそれを "入力して分析ボタンを押してください。" と表示すると仮定
    expect(find.text('入力して分析ボタンを押してください。'), findsOneWidget);
  });

  testWidgets('テキスト入力と分析ボタン押下 - 成功時', (WidgetTester tester) async {
    final mockApiService = MockApiService(); // モックインスタンスを作成

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(mockApiService), // ここでモックを使用
        ],
        child: const MyApp(),
      ),
    );

    await tester.enterText(find.byType(TextField), 'テストの愚痴');
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, '分析する'));
    await tester.pump(); // ローディング開始を検知

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle(); // 非同期処理完了

    expect(find.text('Mocked API Response for "テストの愚痴" with agent "default"'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('テキスト入力と分析ボタン押下 - APIエラー時', (WidgetTester tester) async {
    final mockApiService = MockApiService(); // モックインスタンスを作成

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(mockApiService), // ここでモックを使用
        ],
        child: const MyApp(),
      ),
    );

    await tester.enterText(find.byType(TextField), 'error_case'); // エラーを発生させるテキスト
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, '分析する'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();

    expect(find.textContaining('エラーが発生しました:'), findsOneWidget);
    expect(find.textContaining('Mock API Error'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('テキスト未入力で分析ボタン押下', (WidgetTester tester) async {
    // このテストケースは、apiRequestProviderがnullまたは空文字の時に
    // analyzeResultProviderがエラーを投げ、HomeScreenがそれをハンドルする前提
    final mockApiService = MockApiService();
    await tester.pumpWidget(
      ProviderScope(
         overrides: [
          apiServiceProvider.overrideWithValue(mockApiService),
        ],
        child: const MyApp(),
      ),
    );

    await tester.tap(find.widgetWithText(ElevatedButton, '分析する'));
    await tester.pumpAndSettle(); // SnackBarまたは初期メッセージの表示を待つ

    // HomeScreen側の実装によるが、SnackBarか初期メッセージが表示される
    // _analyzeGuchi メソッド内で空文字チェック＆SnackBar表示があるのでそちらが優先される
    expect(find.text('愚痴を入力してください。'), findsOneWidget); // SnackBarのテキスト
    // あるいは、分析結果エリアが特定のエラー表示になっているか確認
    // 例: expect(find.text('入力して分析ボタンを押してください。'), findsOneWidget);
  });
}