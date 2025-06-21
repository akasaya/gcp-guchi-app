import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/screens/swipe_screen.dart';

// ★★★ 追加: どこからでも参照できるように定数を定義 ★★★
const int MAX_TURNS = 3;

class SessionDetailScreen extends StatefulWidget {
  final String sessionId;

  const SessionDetailScreen({super.key, required this.sessionId});

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final ApiService _apiService = ApiService();
  late final DocumentReference _sessionRef;
  // ★★★ 修正: `summaries` を参照するStreamに変更 ★★★
  Stream<QuerySnapshot>? _summariesStream;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser!;
    _sessionRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('sessions')
        .doc(widget.sessionId);
    
    // ★★★ 修正: `summaries` サブコレクションをターン順で取得するStream ★★★
    _summariesStream = _sessionRef
        .collection('summaries')
        .orderBy('turn', descending: false)
        .snapshots();
  }

  // ... 既存コード ...
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッションの履歴'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _sessionRef.snapshots(),
        builder: (context, sessionSnapshot) {
          if (sessionSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!sessionSnapshot.hasData || !sessionSnapshot.data!.exists) {
            return const Center(child: Text("セッションデータが見つかりません。"));
          }
          final sessionData = sessionSnapshot.data!.data() as Map<String, dynamic>;
          final title = sessionData['title'] ?? sessionData['topic'] ?? '無題のセッション';

          return ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 24),
              // ★★★ 修正: ターン毎の分析結果を表示するUIに戻す ★★★
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

  // ★★★ 修正: ターン毎の分析結果をExpansionTileで表示するウィジェットに戻す ★★★
  Widget _buildAnalysesHistory() {
    return StreamBuilder<QuerySnapshot>(
      stream: _summariesStream,
      builder: (context, summariesSnapshot) {
        if (summariesSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!summariesSnapshot.hasData || summariesSnapshot.data!.docs.isEmpty) {
          return const Text('分析結果がありません。');
        }

        final analyses = summariesSnapshot.data!.docs;
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
                    child: MarkdownBody(
                      data: insights ?? '分析内容がありません。',
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
    // ★★★ 修正: questionsコレクションのクエリを修正 ★★★
    return FutureBuilder<QuerySnapshot>(
      future: _sessionRef.collection('questions').get(), // .orderBy は不要
      builder: (context, questionsSnapshot) {
        if (questionsSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (questionsSnapshot.hasError || !questionsSnapshot.hasData) {
          return const Center(child: Text("質問履歴の読み込みに失敗しました。"));
        }
        
        // ★★★ 修正: 正しいフィールド `question_text` を使用 ★★★
        final questionsMap = { for (var doc in questionsSnapshot.data!.docs) doc.id: doc.get('question_text') as String };

        return StreamBuilder<QuerySnapshot>(
          stream: _sessionRef.collection('swipes').orderBy('timestamp').snapshots(),
          builder: (context, swipesSnapshot) {
             if (swipesSnapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox.shrink();
            }
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
                
                final bool isYes = swipeData['answer'] == true;
                final String answer = isYes ? 'はい' : 'いいえ';
                final Color answerColor = isYes ? Colors.green.shade700 : Colors.red.shade700;

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
        // ★★★ 修正: max_turnsがない場合も考慮し、定数を使用 ★★★
        final int maxTurns = sessionData['max_turns'] ?? MAX_TURNS;
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
                  
                  final navigator = Navigator.of(context);
                  final scaffoldMessenger = ScaffoldMessenger.of(context);
                  
                   try {
                        // ★★★ 修正: 不要な`insights`パラメータを削除 ★★★
                        final result = await _apiService.continueSession(
                          sessionId: widget.sessionId,
                        );
                        final newQuestionsRaw = result['questions'] as List;
                        final newTurn = result['turn'] as int;
                        final newQuestions = List<Map<String, dynamic>>.from(newQuestionsRaw);
                        
                        navigator.pop(); // ローディングダイアログを閉じる
                        navigator.push(
                          MaterialPageRoute(
                            builder: (context) => SwipeScreen(
                              sessionId: widget.sessionId,
                              questions: newQuestions,
                              turn: newTurn,
                            ),
                          ),
                        );
                      } catch (e) {
                        navigator.pop(); // ローディングダイアログを閉じる
                        scaffoldMessenger.showSnackBar(
                          SnackBar(content: Text('エラー: $e')),
                        );
                      }
                },
                child: Text('このセッションを続けて深掘りする (残り$remaining回)'),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}