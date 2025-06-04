import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/home_screen.dart'; // 作成したHomeScreenをインポート

void main() {
  runApp(
    // Riverpodを使用するために、アプリケーションのルートウィジェットをProviderScopeでラップします。
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '愚痴アプリ',
      theme: ThemeData(
        primarySwatch: Colors.blue, // 古い書き方なので、colorSchemeを使った方が現代的
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(), // 初期画面としてHomeScreenを指定
    );
  }
}