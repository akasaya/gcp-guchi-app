import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';
import 'package:frontend/screens/home_screen.dart';

class SummaryScreen extends StatefulWidget {
  final String sessionId;
  final List<Map<String, dynamic>> swipes;

  const SummaryScreen({
    super.key,
    required this.sessionId,
    required this.swipes,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final ApiService _apiService = ApiService();
  Future<Map<String, dynamic>>? _summaryFuture;

  @override
  void initState() {
    super.initState();
    _summaryFuture = _apiService.postSummary(
      sessionId: widget.sessionId,
      swipes: widget.swipes,
    );
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
                SpinKitFadingCube(color: Colors.white, size: 50.0),
                const SizedBox(height: 20),
                Text(message, style: const TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _continueSession(String insights) async {
    _showLoadingDialog('次の質問を考えています...');
    try {
      final result = await _apiService.continueSession(
        sessionId: widget.sessionId,
        insights: insights,
      );
      final newQuestions = List<Map<String, dynamic>>.from(result['questions']);
      final newTurn = result['turn'] as int;

      if (!mounted) return;
      Navigator.of(context).pop();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => SwipeScreen(
            sessionId: widget.sessionId,
            questions: newQuestions,
            turn: newTurn,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラーが発生しました: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('セッションのまとめ'),
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
                    SpinKitFadingCube(color: Colors.deepPurple, size: 50.0),
                    SizedBox(height: 20),
                    Text('AIがあなたの心を分析中...'),
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
            final insights = summaryData['insights'] as String;
            final title = summaryData['title'] as String;
            final currentTurn = summaryData['turn'] as int;
            final maxTurns = summaryData['max_turns'] as int;
            final canContinue = currentTurn < maxTurns;
            final remainingTurns = maxTurns - currentTurn;

            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Markdown(
                        data: insights,
                        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
                          h2: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                          h3: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (canContinue)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.deepPurple,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16)),
                      onPressed: () => _continueSession(insights),
                      child: Text('さらに深掘りする (残り${remainingTurns}回)'),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16)
                    ),
                    onPressed: () {
                      Navigator.of(context).pushAndRemoveUntil(
                        MaterialPageRoute(builder: (context) => const HomeScreen()),
                        (Route<dynamic> route) => false,
                      );
                    },
                    child: const Text('ホームに戻る'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}