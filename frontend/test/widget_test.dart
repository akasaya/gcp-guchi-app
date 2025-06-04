import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart'; // ← あなたの pubspec.yaml の name に置き換えてください

void main() {
  testWidgets('愚痴アプリのタイトルが表示される', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // アプリバーのタイトルを確認
    expect(find.text('愚痴アプリ'), findsOneWidget);
  });

  testWidgets('テキスト入力とボタンが存在する', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // テキスト入力
    expect(find.byType(TextField), findsOneWidget);

    // ボタン
    expect(find.byType(ElevatedButton), findsOneWidget);
    expect(find.text('送信'), findsOneWidget);
  });
}
