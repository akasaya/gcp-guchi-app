import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart'; // ★★★ この行を追加 ★★★

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ApiService _apiService = ApiService();
  // bool _isLoading = false;

  final List<String> _topics = [
    '仕事のこと',
    '人間関係',
    '将来のこと',
    '健康のこと',
    'なんとなく気分が晴れない',
    'その他'
  ];
  String? _selectedTopic;
  String _finalTopic = ''; // 実際にAPIに送るトピック文字列

  User? get currentUser => _auth.currentUser;

  // 改善点③: ローディング表示の統一
  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SpinKitFadingCube( // <- constを削除
                  color: Colors.white,
                  size: 50.0,
                ),
                const SizedBox(height: 20),
                const Text(
                  'AIが質問を考えています...',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        );
      },
    );
  }


    // 改善点⑤: 「その他」選択時の処理
  Future<void> _handleTopicSelection(String topic) async {
    if (topic == 'その他') {
      final customTopic = await showDialog<String>(
        context: context,
        builder: (context) {
          final controller = TextEditingController();
          return AlertDialog(
            title: const Text('トピックを入力してください'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '例：将来のキャリアについて'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    Navigator.of(context).pop(controller.text);
                  }
                },
                child: const Text('決定'),
              ),
            ],
          );
        },
      );
      // ダイアログで入力があった場合のみ更新
      if (customTopic != null && customTopic.isNotEmpty) {
        setState(() {
          _selectedTopic = topic;
          _finalTopic = customTopic;
        });
      }
    } else {
      // 「その他」以外が選択された場合
      setState(() {
        _selectedTopic = topic;
        _finalTopic = topic;
      });
    }
  }


void _startSession() async {
  if (_selectedTopic == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('トピックを選択してください')),
    );
    return;
  }
  
   _showLoadingDialog(); // 変更

 try {
      final sessionData = await _apiService.startSession(_finalTopic); // 変更

      final questionsRaw = sessionData['questions'] as List;
      final questions = List<Map<String, dynamic>>.from(questionsRaw);

      if (!mounted) return;
      Navigator.of(context).pop(); // ローディングを閉じる
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SwipeScreen(
            sessionId: sessionData['session_id'],
            questions: questions,
            turn: 1, // 追加
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // ローディングを閉じる
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラー: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    return Scaffold(
      appBar: AppBar(
        title: Text(user?.displayName != null && user!.displayName!.isNotEmpty
            ? '${user.displayName}さん、こんにちは'
            : 'ホーム'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '過去のセッション履歴',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const HistoryScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'ログアウト',
            onPressed: () async {
              await _auth.signOut();
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.psychology_outlined, size: 60, color: Colors.deepPurple),
                const SizedBox(height: 16),
                const Text(
                  'AIとの対話',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  '今、話したいことは何ですか？\n1つ選んで対話を始めましょう。',
                  style: TextStyle(fontSize: 16, color: Colors.black54),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Wrap(
                  spacing: 12.0,
                  runSpacing: 12.0,
                  alignment: WrapAlignment.center,
                  children: _topics.map((topic) {
                    return ChoiceChip(
                      label: Text(topic, style: const TextStyle(fontSize: 15)),
                      selected: _selectedTopic == topic,
                      onSelected: (selected) {
                        if (selected) {
                          _handleTopicSelection(topic); // 変更
                        }
                      },
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 40),
                // _isLoading の三項演算子を削除
                ElevatedButton.icon(
                  onPressed: _startSession,
                  icon: const Icon(Icons.play_circle_outline),
                        label: const Text('対話を開始する'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 50, vertical: 16),
                          textStyle: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          )
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}