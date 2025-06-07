import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart'; // Firebase Auth をインポート
import 'firebase_options.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/login_screen.dart'; // LoginScreen をインポート

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '愚痴アプリ MVP',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // 認証状態に応じて表示する最初の画面を決定
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(), // 認証状態の変化を監視
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // 最初のフレームではまだ認証状態が確定していない場合があるため、ローディング表示
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (snapshot.hasData) {
            // ユーザーデータがあれば（ログイン済み）、HomeScreenを表示
            return const HomeScreen();
          }
          // ユーザーデータがなければ（未ログイン）、LoginScreenを表示
          return const LoginScreen();
        },
      ),
    );
  }
}