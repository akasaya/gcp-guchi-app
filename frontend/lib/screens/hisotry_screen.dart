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
      return Scaffold(
        appBar: AppBar(title: const Text('セッション履歴')),
        body: const Center(child: Text('ログインしていません。履歴を表示できません。')),
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
            .orderBy('created_at', descending: true) // BUG FIX: 'createdAt' -> 'created_at'
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
              
              final Timestamp? createdAtTimestamp = sessionData['created_at'] as Timestamp?; // BUG FIX: 'createdAt' -> 'created_at'
              String formattedDate = '日時不明';
              if (createdAtTimestamp != null) {
                final DateTime createdAtDate = createdAtTimestamp.toDate();
                formattedDate = DateFormat('yyyy年MM月dd日 HH:mm').format(createdAtDate);
              }

              final String status = sessionData['status'] ?? '不明';
              // BUG FIX: summary is a string now, not a map
              final String summary = sessionData['summary']?.toString() ?? '要約待ち';
              
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: ListTile(
                  title: Text('日時: $formattedDate'),
                  subtitle: Text(
                    'ステータス: $status\n要約: ${summary.length > 50 ? '${summary.substring(0, 50)}...' : summary}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => SessionDetailScreen(sessionId: session.id),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}