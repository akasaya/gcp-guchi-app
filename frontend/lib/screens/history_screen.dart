import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import 'package:frontend/screens/session_detail_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _auth = FirebaseAuth.instance;
  Stream<QuerySnapshot>? _sessionsStream;

  @override
  void initState() {
    super.initState();
    final user = _auth.currentUser;
    if (user != null) {
      _sessionsStream = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('sessions')
          .where('status', whereIn: ['completed', 'error'])
          .orderBy('created_at', descending: true)
          .snapshots();
    }
  }

  String _getSummaryPreview(String? text) {
    if (text == null || text.isEmpty) return '要約がありません';
    
    // Markdownのヘッダーやリストマーカーを除去し、最初の意味のある行を取得
    var lines = text.split('\n').where((line) => line.isNotEmpty && !line.startsWith('#') && !line.startsWith('+ ')).toList();
    return lines.isNotEmpty ? lines.first : '内容のプレビュー';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッション履歴'),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _sessionsStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('エラーが発生しました: ${snapshot.error}'));
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text('セッションの履歴がありません。'),
            );
          }

          final sessions = snapshot.data!.docs;

          return ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              final data = session.data() as Map<String, dynamic>;

              final title = data['title'] ?? data['topic'] ?? '無題のセッション';
              final insights = data['latest_insights'] as String?;
              final timestamp = data['created_at'] as Timestamp?;
              final formattedDate = timestamp != null
                  ? DateFormat('yyyy/MM/dd HH:mm').format(timestamp.toDate())
                  : '日付不明';

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                    _getSummaryPreview(insights),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(formattedDate),
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