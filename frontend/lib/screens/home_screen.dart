import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/services/api_service.dart'; // ApiServiceをインポート
import 'package:frontend/screens/swipe_screen.dart'; // SwipeScreenをインポート
import 'package:frontend/screens/hisotry_screen.dart'; // HistoryScreenをインポート 

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ApiService _apiService = ApiService(); // ApiServiceのインスタンス

  User? get currentUser => _auth.currentUser;

  Future<void> _startNewSession() async {
    if (!mounted) return;
    // ローディング表示などをここに追加しても良い

    try {
      // 以前のセッション開始ロジックをここに移動
      final sessionData = await _apiService.startSession();
      if (mounted && sessionData.containsKey('session_id')) {
        print('Navigating to swipe screen with session: ${sessionData['session_id']}, question: ${sessionData['question_text']}');
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => SwipeScreen(
              sessionId: sessionData['session_id'],
              initialQuestionId: sessionData['question_id'],
              initialQuestionText: sessionData['question_text'],
            ),
          ),
        );
      } else {
        // セッション開始失敗の処理
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('セッションの開始に失敗しました。')),
          );
        }
      }
    } catch (e) {
      print('Error starting new session on HomeScreen: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('セッション開始エラー: ${e.toString()}')),
        );
      }
    }
  }


  Future<void> _logout() async {
    await _auth.signOut();
    // ログアウト後、main.dart の StreamBuilder が検知して LoginScreen に遷移するはず
    // ここで明示的な画面遷移は不要
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ログアウトしました。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ホーム'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'セッション履歴',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => HistoryScreen()), // constを削除
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'ログアウト',
            onPressed: _logout,
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (currentUser != null)
                Text(
                  'ようこそ、${currentUser!.email ?? 'ゲスト'}さん',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _startNewSession, // ボタンを押してセッション開始
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                  textStyle: const TextStyle(fontSize: 18),
                ),
                child: const Text('新しいセッションを開始する'),
              ),
              // ここに過去のセッション履歴の表示などを追加していく
            ],
          ),
        ),
      ),
    );
  }
}