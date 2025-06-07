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
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Widget _buildSummaryContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 50),
              const SizedBox(height: 10),
              Text('サマリーの取得に失敗しました:', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _fetchSummary, // 再試行ボタン
                child: const Text('再試行'),
              ),
            ],
          ),
        ),
      );
    }

    if (_summaryData == null) {
      return const Center(child: Text('サマリーデータがありません。'));
    }

    // 正常にデータが取得できた場合の表示
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch, // 子ウィジェットを横幅いっぱいに広げる
        children: <Widget>[
          Text(
            'セッションが完了しました！',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          if (_summaryData!.containsKey('message') && _summaryData!['message'] is String)
            Text(
              _summaryData!['message'],
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
          const SizedBox(height: 30),
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('セッションID: ${widget.sessionId}', style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 12),
                  const Divider(),
                  const SizedBox(height: 12),
                  if (_summaryData!.containsKey('total_swipes'))
                    Text('総スワイプ数: ${_summaryData!['total_swipes']}', style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  if (_summaryData!.containsKey('yes_count'))
                    Text('「はい」の数: ${_summaryData!['yes_count']}', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.green[700])),
                  const SizedBox(height: 8),
                  if (_summaryData!.containsKey('no_count'))
                    Text('「いいえ」の数: ${_summaryData!['no_count']}', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.red[700])),
                  const SizedBox(height: 8),
                  if (_summaryData!.containsKey('average_speed'))
                    Text('平均スワイプ速度: ${_summaryData!['average_speed']}', style: Theme.of(context).textTheme.bodyLarge),
                ],
              ),
            ),
          ),
          const SizedBox(height: 40),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
            child: const Text('ホームに戻る'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('セッションサマリー'),
        automaticallyImplyLeading: false,
      ),
      body: _buildSummaryContent(),
    );
  }
}