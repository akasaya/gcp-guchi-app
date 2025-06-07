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
      // この画面に来ている時点でログインしているはずなので、本来このエラーは発生しない
      throw Exception('ユーザーがログインしていません。');
    }
    return _firestore
        .collection('users')
        .doc(currentUser.uid)
        .collection('sessions')
        .doc(widget.sessionId)
        .get();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッション詳細'),
      ),
      body: FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        future: _fetchSessionDetails(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('エラーが発生しました: ${snapshot.error}'));
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const Center(child: Text('セッションデータが見つかりません。'));
          }

          final sessionData = snapshot.data!.data();
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

          return Padding(
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
                // TODO: 次のステップで、ここに各スワイプの詳細履歴を表示します。
              ],
            ),
          );
        },
      ),
    );
  }
}