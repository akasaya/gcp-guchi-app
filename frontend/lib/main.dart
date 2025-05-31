import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

// ci test

void main() => runApp(const GuchiApp());

class GuchiApp extends StatelessWidget {
  const GuchiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '愚痴アプリ',
      home: const GuchiPage(),
    );
  }
}

class GuchiPage extends StatefulWidget {
  const GuchiPage({super.key});

  @override
  State<GuchiPage> createState() => _GuchiPageState();
}

class _GuchiPageState extends State<GuchiPage> {
  final TextEditingController _controller = TextEditingController();
  String _result = '';
  bool _isLoading = false;

  Future<void> _sendGuchi() async {
    setState(() {
      _isLoading = true;
      _result = '';
    });

    try {
      final response = await http.post(
        Uri.parse('http://localhost:5000/analyze'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'text': _controller.text}),
      );

      if (response.statusCode == 200) {
        final jsonRes = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _result = jsonRes['results']?.toString() ?? 'レスポンスにresultsがありません';
        });
      } else {
        setState(() {
          _result = 'エラーが発生しました (${response.statusCode})';
        });
      }
    } catch (e) {
      setState(() {
        _result = '送信エラー: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('愚痴アプリ')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                labelText: '愚痴を入力してください',
              ),
              maxLines: null,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _sendGuchi,
              child: _isLoading
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('送信'),
            ),
            const SizedBox(height: 24),
            if (_result.isNotEmpty) ...[
              const Text(
                '分析結果：',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    _result,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}
