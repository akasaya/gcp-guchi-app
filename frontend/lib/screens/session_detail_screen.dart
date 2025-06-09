import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/api_service.dart';
import '../screens/swipe_screen.dart';

class SessionDetailScreen extends StatefulWidget {
  final String sessionId;

  const SessionDetailScreen({super.key, required this.sessionId});

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final ApiService _apiService = ApiService();
  late final DocumentReference _sessionRef;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser!;
    _sessionRef = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('sessions')
        .doc(widget.sessionId);
  }

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
        title: const Text('セッションの履歴'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _sessionRef.snapshots(),
        builder: (context, sessionSnapshot) {
          if (!sessionSnapshot.hasData || !sessionSnapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }
          final sessionData = sessionSnapshot.data!.data() as Map<String, dynamic>;

          return ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              _buildAnalysisCard('AIによるセッションの洞察', sessionData['insights'] ?? '分析がありません。'),
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

  Widget _buildSwipeHistoryList() {
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

        if (sessionData['status'] == 'completed' && currentTurn < 3) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Theme.of(context).colorScheme.onSecondary,
                ),
                onPressed: () async {
                  _showLoadingDialog();
                   try {
                        final result = await _apiService.continueSession(
                          sessionId: widget.sessionId,
                          insights: sessionData['insights'],
                        );
                        final newQuestionsRaw = result['questions'] as List;
                        final newQuestions = List<Map<String, dynamic>>.from(newQuestionsRaw);

                        if (!mounted) return;
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => SwipeScreen(
                              sessionId: widget.sessionId,
                              questions: newQuestions,
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
                child: const Text('このセッションを続けて深掘りする'),
              ),
            ),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}