import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';
import 'package:frontend/screens/hisotry_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ApiService _apiService = ApiService();
  bool _isLoading = false;

  final List<String> _topics = [
    '仕事のこと',
    '人間関係',
    '将来のこと',
    '健康のこと',
    'なんとなく気分が晴れない',
    'その他'
  ];
  String? _selectedTopic;

  User? get currentUser => _auth.currentUser;

void _startSession() async {
  if (_selectedTopic == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('トピックを選択してください')),
    );
    return;
  }
  
  setState(() {
    _isLoading = true;
  });

  try {
    // ★★★ ここの呼び出し方を修正 ★★★
    // final sessionData = await _apiService.startSession(topic: _selectedTopic!); // 修正前
    final sessionData = await _apiService.startSession(_selectedTopic!); // 修正後

    final questionsRaw = sessionData['questions'] as List;
    final questions = List<Map<String, dynamic>>.from(questionsRaw);

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SwipeScreen(
          sessionId: sessionData['session_id'],
          questions: questions,
        ),
      ),
    );
  } catch (e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('エラー: $e')),
    );
  } finally {
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
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
                        setState(() {
                          if (selected) {
                            _selectedTopic = topic;
                          }
                        });
                      },
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 40),
                _isLoading
                    ? const CircularProgressIndicator()
                    : ElevatedButton.icon(
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