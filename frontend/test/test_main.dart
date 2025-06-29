// このファイルはテスト専用のアプリ起動エントリーポイントです。
// main.dart の Firebase.initializeApp() のような、テストに影響を与える
// グローバルな初期化処理を避けるために使用します。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/main.dart'; // MyApp をインポート

void main() {
  // テスト時には、ProviderScopeでラップされたMyAppのみを描画する
  runApp(const ProviderScope(child: MyApp()));
}