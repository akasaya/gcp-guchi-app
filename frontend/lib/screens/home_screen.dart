import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:frontend/screens/analysis_dashboard_screen.dart';
import 'package:frontend/screens/analysis_dashboard_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ApiService _apiService = ApiService();
  Future<HomeSuggestion?>? _suggestionFuture;

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

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  void _fetchData() {
    setState(() {
      _suggestionFuture = _apiService.getHomeSuggestionV2();
    });
  }

  void _showLoadingDialog(String message) {
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
                const SpinKitFadingCube(
                  color: Colors.white,
                  size: 50.0,
                ),
                const SizedBox(height: 20),
                Text(
                  message,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

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
      if (customTopic != null && customTopic.isNotEmpty) {
        setState(() {
          _selectedTopic = topic;
          _finalTopic = customTopic;
        });
      }
    } else {
      setState(() {
        _selectedTopic = topic;
        _finalTopic = topic;
      });
    }
  }

  void _startSession() async {
    if (_finalTopic.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('トピックを選択するか、提案をタップしてください')),
      );
      return;
    }

    _showLoadingDialog('AIが質問を考えています...');

    try {
      final sessionData = await _apiService.startSession(_finalTopic);
      final questionsRaw = sessionData['questions'] as List;
      final questions = List<Map<String, dynamic>>.from(questionsRaw);

      if (!mounted) return;
      Navigator.of(context).pop(); // ローディングを閉じる
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SwipeScreen(
            sessionId: sessionData['session_id'],
            questions: questions,
            turn: 1,
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
            icon: const Icon(Icons.insights_rounded),
            tooltip: '統合分析ダッシュボード',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) => const AnalysisDashboardScreen()),
              );
            },
          ),
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
      body: FutureBuilder<HomeSuggestion?>(
        future: _suggestionFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: SpinKitFadingCube(
                color: Colors.deepPurple,
                size: 50.0,
              ),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.red, size: 60),
                    const SizedBox(height: 16),
                    const Text('データの取得に失敗しました',
                        style: TextStyle(fontSize: 18)),
                    const SizedBox(height: 8),
                    Text(
                      '${snapshot.error}',
                      style: TextStyle(color: Colors.grey.shade600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _fetchData,
                      child: const Text('再試行'),
                    ),
                  ],
                ),
              ),
            );
          }

          final suggestion = snapshot.data;

          return Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    if (suggestion != null) ...[
                      _buildSuggestionCard(suggestion),
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 24),
                    ],
                    const Icon(Icons.psychology_outlined,
                        size: 60, color: Colors.deepPurple),
                    const SizedBox(height: 16),
                    const Text(
                      'AIとの対話',
                      style:
                          TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
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
                          label:
                              Text(topic, style: const TextStyle(fontSize: 15)),
                          selected: _selectedTopic == topic,
                          onSelected: (selected) {
                            if (selected) {
                              _handleTopicSelection(topic);
                            }
                          },
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 40),
                    ElevatedButton.icon(
                      onPressed:
                          _finalTopic.isNotEmpty ? _startSession : null,
                      icon: const Icon(Icons.play_circle_outline),
                      label: const Text('対話を開始する'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 50, vertical: 16),
                          textStyle: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          )),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSuggestionCard(HomeSuggestion suggestion) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => AnalysisDashboardScreen(
                proactiveSuggestion: NodeTapResponse(
                  initialSummary:
                      '「${suggestion.nodeLabel}」について、思考の深掘りを始めましょう。',
                  actions: [],
                  nodeLabel: suggestion.nodeLabel,
                  nodeId: suggestion.nodeId,
                ),
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Icon(Icons.lightbulb_outline,
                  color: Colors.amber.shade700, size: 40),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(suggestion.title,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(
                      suggestion.subtitle,
                      style:
                          TextStyle(fontSize: 14, color: Colors.grey.shade700),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}