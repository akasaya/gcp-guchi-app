import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart'; // 日付整形のため
import 'session_detail_screen.dart'; // この行を追加してください


class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  User? _currentUser;

  @override
  void initState() {
    super.initState();
    _currentUser = _auth.currentUser;
  }

  @override
  Widget build(BuildContext context) {
    if (_currentUser == null) {
      // ユーザーがログインしていない場合の表示 (本来はここまで来ない想定だが念のため)
      return Scaffold(
        appBar: AppBar(
          title: const Text('セッション履歴'),
        ),
        body: const Center(
          child: Text('ログインしていません。履歴を表示できません。'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('セッション履歴'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore
            .collection('users')
            .doc(_currentUser!.uid)
            .collection('sessions')
            .orderBy('createdAt', descending: true) // 新しい順に並べる
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            print('Error fetching history: ${snapshot.error}');
            return const Center(child: Text('履歴の取得中にエラーが発生しました。'));
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('セッション履歴はありません。'));
          }

          final sessions = snapshot.data!.docs;

          return ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              final sessionData = session.data() as Map<String, dynamic>;
              
              // createdAtがTimestamp型であることを想定
              final Timestamp? createdAtTimestamp = sessionData['createdAt'] as Timestamp?;
              String formattedDate = '日時不明';
              if (createdAtTimestamp != null) {
                final DateTime createdAtDate = createdAtTimestamp.toDate();
                // intl パッケージを使って日付をフォーマット
                formattedDate = DateFormat('yyyy年MM月dd日 HH:mm').format(createdAtDate);
              }

              final String status = sessionData['status'] ?? '不明';
              final Map<String, dynamic>? summary = sessionData['summary'] as Map<String, dynamic>?;
              int yesCount = 0;
              int noCount = 0;
              if (summary != null) {
                yesCount = summary['yes_count'] ?? 0;
                noCount = summary['no_count'] ?? 0;
              }

         return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: ListTile(
                  title: Text('セッション日時: $formattedDate'),
                  subtitle: Text('ステータス: $status\nはい: $yesCount, いいえ: $noCount'),
                  isThreeLine: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SessionDetailScreen(sessionId: session.id),
                      ),
                    );
                  }, // ここにカンマが抜けている可能性
                ),
              );
            },
          );
        },
      ),
    );
  }
}