import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';
import 'package:frontend/screens/history_screen.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:frontend/screens/analysis_dashboard_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // ★ _auth と _apiService の late final を削除
  // late final FirebaseAuth _auth;
  // late final ApiService _apiService;

  bool _isLoadingSuggestions = true;
  HomeSuggestion? _proactiveSuggestion;
  String? _fetchError;

  final List<String> _topics = [
    '仕事のこと',
    '人間関係',
    '将来のこと',
    '健康のこと',
    'なんとなく気分が晴れない',
    'その他'
  ];
  String? _selectedTopic;
  String _finalTopic = '';

  // ★ currentUser の取得方法を ref を使うように変更
  User? get currentUser => ref.read(firebaseAuthProvider).currentUser;

  @override
  void initState() {
    super.initState();
    // ★ initStateからref.readを削除し、最初のフレームが描画された後にデータ取得を実行
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _fetchData();
      }
    });
  }

  Future<void> _fetchData() async {
    // ★ メソッド内でapiServiceProviderを読み込む
    final apiService = ref.read(apiServiceProvider);
    if (!mounted) return;

    setState(() {
      _isLoadingSuggestions = true;
      _fetchError = null;
    });

    try {
      final suggestion = await apiService.getHomeSuggestionV2();
      if (mounted) {
        setState(() {
          _proactiveSuggestion = suggestion;
          _isLoadingSuggestions = false;
        });
      }
    } catch (e) {
      if (mounted) {
        // ★ ログアウト時にAPI呼び出しが失敗した場合、エラー表示しないようにする

          setState(() {
            _fetchError = '提案の取得に失敗しました。';
            _isLoadingSuggestions = false;
          });
      }
      debugPrint("ホーム画面のデータ取得に失敗: $e");
    }
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

  void _startSession() {
    _startSessionWithTopic(_finalTopic);
  }

  void _startSessionWithTopic(String topic) async {
    // ★ メソッド内でapiServiceProviderを読み込む
    final apiService = ref.read(apiServiceProvider);

    if (topic.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('トピックが空です')),
      );
      return;
    }
    _showLoadingDialog('AIが質問を考えています...');
    try {
      final sessionData = await apiService.startSession(topic);
      final questionsRaw = sessionData['questions'] as List;
      final questions = List<Map<String, dynamic>>.from(questionsRaw);
      if (!mounted) return;
      Navigator.of(context).pop();
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SwipeScreen(
            sessionId: sessionData['session_id'],
            questions: questions,
            turn: 1,
            apiService: apiService, // ★ ここでApiServiceを渡す
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラー: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
      title: const Text('マインドソート'),
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
              await ref.read(authServiceProvider).signOut();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchData,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            children: <Widget>[
              // --- 上部の提案セクション ---
              _buildSuggestionSection(),
              // --- 中央の対話セクション ---
              Expanded(
                child: Container(
                  alignment: const Alignment(0.0, -0.4), 
                  child: SingleChildScrollView(
                    child: _buildDialogueSection(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDialogueSection() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Icon(Icons.psychology_outlined,
            size: 60, color: Colors.deepPurple),
        const SizedBox(height: 16),
        const Text(
          'AIとの対話',
          style: TextStyle(
              fontSize: 28, fontWeight: FontWeight.bold),
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
              label: Text(topic,
                  style: const TextStyle(fontSize: 15)),
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
          key: const Key('start_session_button'),
          onPressed:
              _finalTopic.isNotEmpty ? _startSession : null,
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('対話を開始する'),
          style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade300,
              padding: const EdgeInsets.symmetric(
                  horizontal: 30, vertical: 15),
              textStyle: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              )),
        ),
      ],
    );
  }

  Widget _buildSuggestionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _buildSectionHeader('話題の提案'),
        const SizedBox(height: 12),
        
        _isLoadingSuggestions
            ? const Center(child: CircularProgressIndicator())
            : _fetchError != null
                ? Center(
                    child: Column(
                      children: [
                        const Icon(Icons.cloud_off, color: Colors.grey, size: 40),
                        const SizedBox(height: 8),
                        Text(_fetchError!, style: TextStyle(color: Colors.grey.shade700)),
                        const SizedBox(height: 8),
                        TextButton(
                          key: const Key('retry_button'),
                          onPressed: _fetchData,
                          child: const Text('再試行'),
                        ),
                      ],
                    ),
                  )
                : _proactiveSuggestion != null
                    ? _buildProactiveSuggestionCard(_proactiveSuggestion!)
                    : _buildNoSuggestionCard(),
        
        const Divider(height: 32, thickness: 1),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4.0, bottom: 8.0),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleLarge
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildNoSuggestionCard() {
    return Card(
      elevation: 0,
      color: Colors.grey.shade100,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.grey.shade500, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                '複数回対話が完了すると、AIがここでおすすめの話題を提案します。',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProactiveSuggestionCard(HomeSuggestion suggestion) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _startSessionWithTopic(suggestion.nodeLabel),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Icon(Icons.lightbulb_outline,
                  color: Colors.amber.shade700, size: 32),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('過去の対話を深掘りしてみませんか',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
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