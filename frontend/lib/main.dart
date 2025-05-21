import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  runApp(const GuchiApp());
}


class GuchiApp extends StatelessWidget {
  const GuchiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const GuchiInputPage(),
    );
  }
}

class GuchiInputPage extends StatefulWidget {
  const GuchiInputPage({super.key});

  @override
  State<GuchiInputPage> createState() => _GuchiInputPageState();
}

class _GuchiInputPageState extends State<GuchiInputPage> {
  final TextEditingController _controller = TextEditingController();
  String _result = '';

  Future<void> analyzeGuchi() async {
    final response = await http.post(
      Uri.parse('http://localhost:5000/analyze'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'text': _controller.text}),
    );

    final data = jsonDecode(response.body);
    setState(() {
      _result = data['result'];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('愚痴分析くん')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '愚痴を入力してください',
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: analyzeGuchi,
              child: const Text('送信'),
            ),
            const SizedBox(height: 12),
            Text(_result),
          ],
        ),
      ),
    );
  }
}
