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
  // ★★★ 修正: _summaryFutureを削除し、_sessionStreamを定義 ★★★
  Stream<DocumentSnapshot>? _sessionStream;
  bool _isContinuing = false;

  @override
  void initState() {
    super.initState();
    // ★★★ 修正: _summaryFutureの初期化を削除し、_sessionStreamを初期化 ★★★
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
                // ★★★ 修正: ローディングアニメーションを四角形に統一 ★★★
                const SpinKitFadingCube(color: Colors.white, size: 50.0),
                const SizedBox(height: 20),
                Text(message, style: const TextStyle(color: Colors.white, fontSize: 16)),
              ],
            ),
          ),
        );
      },
    );
  }

// ★★★ 修正: 不要になった `String insights` パラメータをメソッド定義から完全に削除 ★★★
Future<void> _continueSession() async {
    // ★★★ 追加: 処理開始時にフラグを立ててUIを更新 ★★★
    setState(() {
      _isContinuing = true;
    });
    _showLoadingDialog('次の質問を考えています...');

    // awaitの前にNavigatorとScaffoldMessengerをキャプチャ
    final navigator = Navigator.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      // APIの仕様変更に伴い、insightsは不要になりました
      final result = await _apiService.continueSession(
        sessionId: widget.sessionId,
      );
      final newQuestions = List<Map<String, dynamic>>.from(result['questions']);
      final newTurn = result['turn'] as int;

      // キャプチャしたnavigatorを使用
      navigator.pop(); // ローディングダイアログを閉じる
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
      // キャプチャしたnavigatorとscaffoldMessengerを使用
      navigator.pop(); // ローディングダイアログを閉じる
      scaffoldMessenger.showSnackBar(
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
        // ★★★ 修正: FutureBuilderからStreamBuilderに全面的に変更 ★★★
        body: StreamBuilder<DocumentSnapshot>(
          stream: _sessionStream,
          builder: (context, snapshot) {
            // データがまだ来ていない、または接続中
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

            // エラー発生 or データが存在しない
            if (snapshot.hasError || !snapshot.hasData || !snapshot.data!.exists) {
              return const Center(child: Text('分析結果の取得に失敗しました。'));
            }

            final sessionData = snapshot.data!.data() as Map<String, dynamic>;
            final status = sessionData['status'] as String?;

            // ★★★ 修正: _isContinuingフラグがtrueの間は、本体のローディング表示を抑制 ★★★
            // バックエンドが処理中の場合
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
            
            // バックエンドでエラーが発生した場合
            if (status == 'error') {
              final errorMessage = sessionData['error_message'] ?? '不明なエラーが発生しました。';
              return Center(child: Text('分析結果の取得に失敗しました: $errorMessage'));
            }

            // ここまで来れば status == 'completed'
            final insights = sessionData['latest_insights'] as String? ?? '分析結果のテキストがありません。';
            final title = sessionData['title'] as String? ?? '無題';
            final currentTurn = sessionData['turn'] as int? ?? 1;
            final maxTurns = sessionData['max_turns'] as int? ?? 3;
            
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
                      // ★★★ 修正: 引数なしになったメソッドを直接渡すことでエラー解消 ★★★
                      onPressed: _continueSession,
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