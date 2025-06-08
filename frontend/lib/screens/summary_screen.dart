import 'package:flutter/material.dart';
import '../services/api_service.dart'; // ApiService をインポート

class SummaryScreen extends StatefulWidget {
  final String sessionId;

  const SummaryScreen({super.key, required this.sessionId});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen> {
  final ApiService _apiService = ApiService();
  Map<String, dynamic>? _summaryData;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _fetchSummary();
  }

  Future<void> _fetchSummary() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
        final data = await _apiService.getSummary(widget.sessionId);
        if (mounted) {
          setState(() {
            _summaryData = data;
            _isLoading = false;
          });
      }
    } catch (e) {
      print('Error in _fetchSummary: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッションサマリー'),
        automaticallyImplyLeading: false, // 戻るボタンを非表示に
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      'サマリーの取得に失敗しました。\n$_errorMessage',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(
                        child: Icon(
                          Icons.check_circle_outline,
                          color: Colors.green,
                          size: 60,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: Text(
                          'セッションが完了しました！',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _buildInfoCard(
                        title: 'セッションID',
                        content: widget.sessionId,
                      ),
                      const SizedBox(height: 16),
                      if (_summaryData != null) ...[
                        _buildInfoCard(
                          title: 'AIによる要約',
                          content: _summaryData!['summary'] ?? '要約はありません。',
                        ),
                        const SizedBox(height: 16),
                        _buildInfoCard(
                          title: 'AIによる行動分析',
                          content: _summaryData!['interaction_analysis'] ?? '分析データはありません。',
                        ),
                      ],
                      const SizedBox(height: 32),
                      Center(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.of(context).popUntil((route) => route.isFirst);
                          },
                          child: const Text('ホームに戻る'),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildInfoCard({required String title, required String content}) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(content),
          ],
        ),
      ),
    );
  }
}