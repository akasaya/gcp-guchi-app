import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/api_providers.dart'; // 作成したプロバイダをインポート

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _textEditingController = TextEditingController();
  // (オプション) もしエージェント名をユーザーが選択できるようにする場合
  // String? _selectedAgentName;

  @override
  void dispose() {
    _textEditingController.dispose();
    super.dispose();
  }

  void _analyzeGuchi() {
    final text = _textEditingController.text;
    if (text.isNotEmpty) {
      // apiRequestProviderの値を更新 (名前付きフィールドを持つレコードを代入)
      ref.read(apiRequestProvider.notifier).state = (text: text, agentName: null /* _selectedAgentName */);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('愚痴を入力してください。')),
      );
    }
  }


  @override
  Widget build(BuildContext context) {
    // analyzeResultProviderを監視し、その状態に応じてUIを構築
    final asyncAnalyzeResult = ref.watch(analyzeResultProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('愚痴アプリ'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '今日の愚痴をどうぞ:',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textEditingController,
              decoration: const InputDecoration(
                hintText: 'ここに愚痴を入力...',
                border: OutlineInputBorder(),
              ),
              maxLines: 5,
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _analyzeGuchi,
              child: const Text('分析する'),
            ),
            const SizedBox(height: 30),
            Text(
              '分析結果:',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Card(
                elevation: 2,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  // FutureProviderの状態に応じて表示を切り替える
                  child: asyncAnalyzeResult.when(
                    data: (analyzeResponse) {
                      // APIから正常にレスポンスが返ってきた場合
                      return SingleChildScrollView(child: Text(analyzeResponse.results));
                    },
                    loading: () {
                      // ローディング中の表示
                      // apiRequestProviderがnullの初期状態では、FutureProviderは実行されないため、
                      // 初回表示時やテキストクリア時にはローディングにはなりません。
                      // _analyzeGuchi が呼ばれた後、Futureが完了するまでローディングになります。
                      final request = ref.watch(apiRequestProvider);
                      // リクエストが発行された後だけローディング表示
                      return request != null ? const Center(child: CircularProgressIndicator()) : const Text('入力して分析ボタンを押してください。');
                    },
                    error: (error, stackTrace) {
                      // エラーが発生した場合
                      // 初期状態や入力が空でエラーを投げた場合もここに来る
                      if (error.toString().contains('Input text is empty')) {
                         return const Text('入力して分析ボタンを押してください。');
                      }
                      return Text('エラーが発生しました: $error');
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}