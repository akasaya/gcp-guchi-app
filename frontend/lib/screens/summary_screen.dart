import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class SummaryScreen extends StatefulWidget {
  final String sessionId;

  const SummaryScreen({
    super.key,
    required this.sessionId,
  });

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final ApiService _apiService = ApiService();
  Stream<DocumentSnapshot>? _sessionStream;
  bool _isContinuing = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _sessionStream = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('sessions')
          .doc(widget.sessionId)
          .snapshots();
    }
  }

    void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SpinKitFadingCube(
                  color: Colors.white,
                  size: 50.0,
                ),
                SizedBox(height: 20),
                Text("次の質問を考えています...",
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
          ),
        );
      },
    );
  }

  void _hideLoadingDialog() {
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
  
  Future<void> _continueSession() async {
    if (_isContinuing) return;

    setState(() {
      _isContinuing = true;
    });
    _showLoadingDialog();

    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      final result = await _apiService.continueSession(
        sessionId: widget.sessionId,
      );
      final newQuestions = List<Map<String, dynamic>>.from(result['questions']);
      final newTurn = result['turn'] as int;

      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (context) => SwipeScreen(
            sessionId: widget.sessionId,
            questions: newQuestions,
            turn: newTurn,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        _hideLoadingDialog();
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text('エラーが発生しました: $e')),
        );
        setState(() {
          _isContinuing = false;
        });
      }
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
        body: StreamBuilder<DocumentSnapshot>(
          stream: _sessionStream,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
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

            if (snapshot.hasError || !snapshot.hasData || !snapshot.data!.exists) {
              return const Center(child: Text('分析結果の取得に失敗しました。'));
            }

            final sessionData = snapshot.data!.data() as Map<String, dynamic>;
            final status = sessionData['status'] as String?;

            // 2. バックエンドで最初の要約を処理中のローディング画面を表示
            if (status != 'completed' && status != 'error' && !_isContinuing) {
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
            
            if (status == 'error') {
              final errorMessage = sessionData['error_message'] ?? '不明なエラーが発生しました。';
              return Center(child: Text('分析結果の取得に失敗しました: $errorMessage'));
            }

            final insights = sessionData['latest_insights'] as String? ?? '分析結果のテキストがありません。';
            final title = sessionData['title'] as String? ?? '無題';
            final currentTurn = sessionData['turn'] as int? ?? 1;
            final maxTurns = sessionData['max_turns'] as int? ?? 5;
            
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
                      onPressed: _isContinuing ? null : _continueSession,
                      child: Text('さらに深掘りする (残り$remainingTurns回)'),
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