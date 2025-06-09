import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../screens/swipe_screen.dart';

class SummaryScreen extends StatefulWidget {
  final String sessionId;

  const SummaryScreen({super.key, required this.sessionId});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final ApiService _apiService = ApiService();
  late Future<Map<String, dynamic>> _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _apiService.getSummary(widget.sessionId);
  }

  // ★ ローディングダイアログを表示するメソッド
  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Dialog(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 20),
                Text("次の質問を生成中..."),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('今回のセッションの分析'),
        automaticallyImplyLeading: false,
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _summaryFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('AIが分析中です...'),
                ],
              ),
            );
          }
          if (snapshot.hasError) {
            return Center(child: Text('分析結果の取得に失敗しました: ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: Text('分析結果がありません。'));
          }

          final summaryData = snapshot.data!;
          // ★ 表示を統合
          return _buildAnalysisContent(summaryData);
        },
      ),
      bottomNavigationBar: _buildBottomButtons(),
    );
  }

  Widget _buildAnalysisContent(Map<String, dynamic> summaryData) {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        _buildAnalysisCard(
          'AIによるセッションの洞察', // ★ タイトルを統一
          summaryData['insights'] ?? '分析結果の読み込みに失敗しました。', // ★ 表示データをinsightsに統一
        ),
      ],
    );
  }
  
  Widget _buildBottomButtons() {
    return FutureBuilder<Map<String, dynamic>>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.hasError) {
          return const SizedBox.shrink();
        }
        final summaryData = snapshot.data!;
        final int currentTurn = summaryData['turn'] ?? 1;

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                    child: const Text('終了する'),
                  ),
                ),
                const SizedBox(width: 16),
                // ★ ターン数が3未満の場合のみボタンを表示
                if (currentTurn < 3)
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      ),
                      onPressed: () async {
                        _showLoadingDialog(); // ローディング表示開始
                        try {
                          final result = await _apiService.continueSession(
                            sessionId: widget.sessionId,
                            insights: summaryData['insights'], // ★ insightsを渡す
                          );
                          final newQuestionsRaw = result['questions'] as List;
                          final newQuestions = List<Map<String, dynamic>>.from(newQuestionsRaw);

                          if (!mounted) return;
                          Navigator.of(context).pop(); // ローディング表示を閉じる
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (context) => SwipeScreen(
                                sessionId: widget.sessionId,
                                questions: newQuestions,
                              ),
                            ),
                          );
                        } catch (e) {
                          if (!mounted) return;
                          Navigator.of(context).pop(); // エラー時もローディング表示を閉じる
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('エラーが発生しました: $e')),
                          );
                        }
                      },
                      child: const Text('さらに深掘りする'),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAnalysisCard(String title, String content) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(content),
          ),
        ),
      ],
    );
  }
}