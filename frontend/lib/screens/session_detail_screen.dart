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

  Stream<DocumentSnapshot<Map<String, dynamic>>> _sessionDetailsStream() {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.error('User not logged in');
    }
    return _firestore
        .collection('users')
        .doc(user.uid)
        .collection('sessions')
        .doc(widget.sessionId)
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _fetchSwipes() {
    final user = _auth.currentUser;
    if (user == null) {
      return Stream.error('User not logged in');
    }
    return _firestore
        .collection('users')
        .doc(user.uid)
        .collection('sessions')
        .doc(widget.sessionId)
        .collection('swipes')
        .orderBy('timestamp', descending: false)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッション詳細'),
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _sessionDetailsStream(),
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
          
          // BUG FIX: 'createdAt' -> 'created_at'
          final Timestamp? createdAtTimestamp = sessionData['created_at'] as Timestamp?;
          String formattedDate = '日時不明';
          if (createdAtTimestamp != null) {
            final DateTime createdAtDate = createdAtTimestamp.toDate();
            formattedDate = DateFormat('yyyy年MM月dd日 HH:mm:ss').format(createdAtDate);
          }

          final String status = sessionData['status'] ?? '不明';
          // BUG FIX: Handle summary being a String to avoid TypeError.
          final String summary = sessionData['summary']?.toString() ?? 'AIによる振り返りはまだありません。';
          final String gemmaAnalysis = sessionData['gemma_interaction_analysis']?.toString() ?? '行動分析データはありません。';
          
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSectionTitle('セッション情報'),
                _buildInfoCard([
                  _buildInfoRow('日時', formattedDate),
                  _buildInfoRow('ステータス', status),
                ]),
                const SizedBox(height: 24),

                _buildSectionTitle('AIによる振り返り'),
                _buildInfoCard([
                  Text(summary),
                ]),
                const SizedBox(height: 24),
                
                _buildSectionTitle('あなたの心の動きの分析'),
                _buildInfoCard([
                  Text(gemmaAnalysis),
                ]),
                const SizedBox(height: 24),

                _buildSectionTitle('スワイプ履歴'),
                _buildSwipesList(),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildInfoCard(List<Widget> children) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80, // ラベルの幅を固定
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildSwipesList() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _fetchSwipes(),
      builder: (context, swipeSnapshot) {
        if (swipeSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (swipeSnapshot.hasError) {
          return Text('スワイプ履歴の読み込みに失敗しました: ${swipeSnapshot.error}');
        }
        if (!swipeSnapshot.hasData || swipeSnapshot.data!.docs.isEmpty) {
          return const Text('スワイプ履歴はありません。');
        }

        final swipes = swipeSnapshot.data!.docs;

        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(), // SingleChildScrollView内で使うため
          itemCount: swipes.length,
          itemBuilder: (context, index) {
            final swipeData = swipes[index].data();
            final questionRef = swipeData['question_ref'] as DocumentReference?;
            
            return FutureBuilder<DocumentSnapshot>(
              future: questionRef?.get(),
              builder: (context, questionDocSnapshot) {
                String questionText = '質問を読み込み中...';
                if (questionDocSnapshot.connectionState == ConnectionState.done) {
                   if (questionDocSnapshot.hasData && questionDocSnapshot.data!.exists) {
                     final questionData = questionDocSnapshot.data!.data() as Map<String, dynamic>;
                     questionText = questionData['text'] ?? '質問テキストが見つかりません';
                   } else {
                     questionText = '質問が見つかりません';
                   }
                }

                final answer = swipeData['answer'] ?? '回答不明';
                final hesitation = (swipeData['hesitation_time_sec'] ?? 0).toStringAsFixed(2);
                final duration = swipeData['swipe_duration_ms'] ?? 0;
                
                final Color iconColor = answer.toLowerCase() == 'yes' ? Colors.green : Colors.red;
                final IconData iconData = answer.toLowerCase() == 'yes' ? Icons.check_circle_outline : Icons.cancel_outlined;

                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 4.0),
                  child: ListTile(
                    leading: Icon(iconData, color: iconColor),
                    title: Text(questionText),
                    subtitle: Text('回答: $answer (ためらい: ${hesitation}秒, 速度: ${duration}ms)'),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}