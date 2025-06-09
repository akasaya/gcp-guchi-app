import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';

class SessionDetailScreen extends StatefulWidget {
  final String sessionId;

  const SessionDetailScreen({super.key, required this.sessionId});

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final ApiService _apiService = ApiService();
  late final DocumentReference _sessionRef;
  Stream<QuerySnapshot>? _analysesStream;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser!;
    _sessionRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('sessions')
        .doc(widget.sessionId);
    
    // ターン毎の分析結果を取得するStream
    _analysesStream = _sessionRef
        .collection('analyses')
        .orderBy('turn', descending: false)
        .snapshots();
  }

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
              children: [ // <- `const` を `children:` の手前から削除
                const SpinKitFadingCube(color: Colors.white, size: 50.0),
                const SizedBox(height: 20),
                const Text("次の質問を生成中...", style: TextStyle(color: Colors.white, fontSize: 16)),
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
        title: const Text('セッションの履歴'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _sessionRef.snapshots(),
        builder: (context, sessionSnapshot) {
          if (!sessionSnapshot.hasData || !sessionSnapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final sessionData = sessionSnapshot.data!.data() as Map<String, dynamic>;
          final title = sessionData['title'] ?? sessionData['topic'] ?? '無題のセッション';

          return ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              // 改善点②: ターン毎の分析結果を表示
              _buildAnalysesHistory(),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              Text('回答の全履歴', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              _buildSwipeHistoryList(),
            ],
          );
        },
      ),
      bottomNavigationBar: _buildContinueButton(),
    );
  }

  // 改善点②: ターン毎の分析結果をExpansionTileで表示するウィジェット
  Widget _buildAnalysesHistory() {
    return StreamBuilder<QuerySnapshot>(
      stream: _analysesStream,
      builder: (context, analysesSnapshot) {
        if (analysesSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!analysesSnapshot.hasData || analysesSnapshot.data!.docs.isEmpty) {
          return const Text('分析結果がありません。');
        }

        final analyses = analysesSnapshot.data!.docs;
        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: analyses.length,
          itemBuilder: (context, index) {
            final analysis = analyses[index].data() as Map<String, dynamic>;
            final turn = analysis['turn'];
            final insights = analysis['insights'];

            return Card(
              elevation: 2,
              margin: const EdgeInsets.symmetric(vertical: 8.0),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: ExpansionTile(
                title: Text('ターン $turn の分析結果', style: const TextStyle(fontWeight: FontWeight.bold)),
                initiallyExpanded: index == analyses.length - 1, // 最新のタイルをデフォルトで開く
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 16.0),
                    // 改善点①: Markdownで表示
                    child: MarkdownBody(
                      data: insights,
                      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildSwipeHistoryList() {
    // この部分は既存のロジックを流用可能
    return FutureBuilder<QuerySnapshot>(
      future: _sessionRef.collection('questions').orderBy('order').get(),
      builder: (context, questionsSnapshot) {
        if (!questionsSnapshot.hasData) return const Center(child: CircularProgressIndicator());
        
        final questionsMap = { for (var doc in questionsSnapshot.data!.docs) doc.id: doc.get('text') as String };

        return StreamBuilder<QuerySnapshot>(
          stream: _sessionRef.collection('swipes').orderBy('timestamp').snapshots(),
          builder: (context, swipesSnapshot) {
            if (!swipesSnapshot.hasData) return const Center(child: Text("回答を読み込み中..."));
            if (swipesSnapshot.data!.docs.isEmpty) return const Center(child: Text("回答履歴がありません。"));
            
            return ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: swipesSnapshot.data!.docs.length,
              itemBuilder: (context, index) {
                final swipeData = swipesSnapshot.data!.docs[index].data() as Map<String, dynamic>;
                final questionId = swipeData['question_id'] as String;
                final questionText = questionsMap[questionId] ?? '質問の読み込みに失敗';
                final answer = swipeData['answer'] == 'yes' ? 'はい' : 'いいえ';
                final answerColor = swipeData['answer'] == 'yes' ? Colors.green : Colors.red;

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ListTile(
                    title: Text(questionText),
                    trailing: Text(answer, style: TextStyle(color: answerColor, fontWeight: FontWeight.bold)),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildContinueButton() {
    return StreamBuilder<DocumentSnapshot>(
      stream: _sessionRef.snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) return const SizedBox.shrink();
        
        final sessionData = snapshot.data!.data() as Map<String, dynamic>;
        final int currentTurn = sessionData['turn'] ?? 1;
        final int maxTurns = sessionData['max_turns'] ?? 3;
        final bool canContinue = currentTurn < maxTurns && sessionData['status'] == 'completed';

        if (canContinue) {
          final remaining = maxTurns - currentTurn;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: () async {
                  _showLoadingDialog();
                   try {
                        final result = await _apiService.continueSession(
                          sessionId: widget.sessionId,
                          insights: sessionData['latest_insights'],
                        );
                        final newQuestionsRaw = result['questions'] as List;
                        final newTurn = result['turn'] as int;
                        final newQuestions = List<Map<String, dynamic>>.from(newQuestionsRaw);

                        if (!mounted) return;
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
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
                          SnackBar(content: Text('エラー: $e')),
                        );
                      }
                },
                // 改善点④: 残回数を表示
                child: Text('このセッションを続けて深掘りする (残り${remaining}回)'),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}