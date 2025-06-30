import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/providers/auth_provider.dart'; 
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';

// ─ mock 定義 ────────────────────────────────────
class MockApiService extends Mock implements ApiService {}

class FakePrefs extends Fake implements SharedPreferences {
  final _data = <String, Object?>{};
  @override bool? getBool(String key) => _data[key] as bool?;
  @override
  Future<bool> setBool(String key, bool value) async {
    _data[key] = value;   // 保存する
    return true;          // <- 必ず bool を返す
  }
}

void main() {
  late MockApiService api;
  late FakePrefs      prefs;
  late MockFirebaseAuth auth;

  setUp(() {
    api   = MockApiService();
    prefs = FakePrefs()..setBool('onboarding_completed', true);

    // MockUser は実体なのでスタブしない
    final user = MockUser(uid: 'uid', displayName: 'テストユーザー');
    auth = MockFirebaseAuth(mockUser: user);
  });

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(
      ProviderScope(overrides: [
        apiServiceProvider.overrideWithValue(api),
        firebaseAuthProvider.overrideWithValue(auth),
        sharedPreferencesProvider.overrideWith((_) async => prefs),
      ], child: const MaterialApp(home: HomeScreen())),
    );
  }

  testWidgets('ローディング表示', (t) async {
    final completer = Completer<HomeSuggestion?>();
    when(() => api.getHomeSuggestionV2())
        .thenAnswer((_) => completer.future);

    await pump(t);
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('成功表示', (t) async {
    final sug = HomeSuggestion(
      title: 'Success', nodeId: 'id', nodeLabel: 'lbl', subtitle: 'done');
    when(() => api.getHomeSuggestionV2())
        .thenAnswer((_) async => sug);          // ← thenAnswer を使用

    await pump(t);
    await t.pumpAndSettle();

    expect(find.text('話題の提案'), findsOneWidget);
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('失敗表示', (t) async {
    when(() => api.getHomeSuggestionV2())
        .thenThrow(Exception('err'));

    await pump(t);
    await t.pumpAndSettle();

    expect(find.text('提案の取得に失敗しました。'), findsOneWidget);
  });

  testWidgets('再試行ボタンで 2 回呼ばれる', (t) async {
    when(() => api.getHomeSuggestionV2()).thenThrow(Exception('first'));

    await pump(t);
    await t.pumpAndSettle();
    verify(() => api.getHomeSuggestionV2()).called(1);

    reset(api); // 既存スタブを解除し Bad state を防ぐ

    final retry = HomeSuggestion(
      title: 'Retry', nodeId: 'r', nodeLabel: 'r', subtitle: 'ret ok');
    when(() => api.getHomeSuggestionV2())
        .thenAnswer((_) async => retry);

    await t.tap(find.byKey(const Key('retry_button')));
    await t.pumpAndSettle();

    verify(() => api.getHomeSuggestionV2()).called(1);
    expect(find.text('ret ok'), findsOneWidget);
  });
}
