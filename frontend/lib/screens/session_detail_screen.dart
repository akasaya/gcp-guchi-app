import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';

class SessionDetailScreen extends StatefulWidget {
  final String sessionId;

  const SessionDetailScreen({super.key, required this.sessionId});

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  Future<DocumentSnapshot<Map<String, dynamic>>> _fetchSessionDetails() {
    final User? currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw Exception('ユーザーがログインしていません。');
    }
    return _firestore
        .collection('users')
        .doc(currentUser.uid)
        .collection('sessions')
        .doc(widget.sessionId)
        .get();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _fetchSwipes() {
    final User? currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw Exception('ユーザーがログインしていません。');
    }
    return _firestore
        .collection('users')
        .doc(currentUser.uid)
        .collection('sessions')
        .doc(widget.sessionId)
        .collection('swipes')
        .orderBy('swiped_at', descending: false) // 時系列順に表示
        .snapshots();
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッション詳細'),
      ),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: _fetchSessionDetails(),
        builder: (context, sessionSnapshot) {
          if (sessionSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (sessionSnapshot.hasError) {
            return Center(child: Text('エラーが発生しました: ${sessionSnapshot.error}'));
          }
          if (!sessionSnapshot.hasData || !sessionSnapshot.data!.exists) {
            return const Center(child: Text('セッションデータが見つかりません。'));
          }

          final sessionData = sessionSnapshot.data!.data();
          if (sessionData == null) {
            return const Center(child: Text('セッションデータが空です。'));
          }
          
          final Timestamp? createdAtTimestamp = sessionData['createdAt'] as Timestamp?;
          String formattedDate = '日時不明';
          if (createdAtTimestamp != null) {
            final DateTime createdAtDate = createdAtTimestamp.toDate();
            formattedDate = DateFormat('yyyy年MM月dd日 HH:mm:ss').format(createdAtDate);
          }

          final String status = sessionData['status'] ?? '不明';
          final Map<String, dynamic>? summary = sessionData['summary'] as Map<String, dynamic>?;
          int yesCount = 0;
          int noCount = 0;
          if (summary != null) {
            yesCount = summary['yes_count'] ?? 0;
            noCount = summary['no_count'] ?? 0;
          }

          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('セッション情報', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      title: Text('日時: $formattedDate'),
                      subtitle: Text('ステータス: $status'),
                    ),
                  ),
                  const Divider(height: 32),
                  Text('サマリー', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Card(
                    child: ListTile(
                      title: Text('はい: $yesCount 回'),
                      subtitle: Text('いいえ: $noCount 回'),
                    ),
                  ),
                  const Divider(height: 32),
                  Text('スワイプ履歴', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: _fetchSwipes(),
                    builder: (context, swipeSnapshot) {
                      if (swipeSnapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (swipeSnapshot.hasError) {
                        return Center(child: Text('スワイプ履歴の取得エラー: ${swipeSnapshot.error}'));
                      }
                      if (!swipeSnapshot.hasData || swipeSnapshot.data!.docs.isEmpty) {
                        return const Center(child: Text('スワイプ履歴はありません。'));
                      }

                      final swipes = swipeSnapshot.data!.docs;

                      return ListView.builder(
                        itemCount: swipes.length,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemBuilder: (context, index) {
                          final swipeData = swipes[index].data();
                          final String questionText = swipeData['question_text'] ?? '質問テキスト不明';
                          final String direction = swipeData['direction'] ?? '不明';
                          final double velocity = (swipeData['velocity'] as num?)?.toDouble() ?? 0.0;
                          
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4.0),
                            child: ListTile(
                              leading: Icon(
                                direction == 'yes' ? Icons.check_circle_outline : Icons.highlight_off,
                                color: direction == 'yes' ? Colors.green : Colors.red,
                              ),
                              title: Text(questionText),
                              subtitle: Text('回答: ${direction.toUpperCase()} (速度: ${velocity.toStringAsFixed(2)})'),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}