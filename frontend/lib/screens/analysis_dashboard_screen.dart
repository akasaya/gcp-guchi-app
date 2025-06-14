import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/graph_data.dart' as model;
import 'package:frontend/services/api_service.dart';
import 'package:graphview/GraphView.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:uuid/uuid.dart';

class AnalysisDashboardScreen extends ConsumerStatefulWidget {
  const AnalysisDashboardScreen({super.key});

  @override
  ConsumerState<AnalysisDashboardScreen> createState() =>
      _AnalysisDashboardScreenState();
}

class _AnalysisDashboardScreenState extends ConsumerState<AnalysisDashboardScreen> {
  Future<model.GraphData>? _graphDataFuture;
  final Graph _graph = Graph();
  // iterationsを200から150に減らし、計算速度を少し上げる
  final Algorithm _algorithm = FruchtermanReingoldAlgorithm(iterations: 150);
  Map<String, model.Node> _nodeDataMap = {};

  // --- チャット用の状態変数 ---
  final List<types.Message> _messages = [];
  final _user = const types.User(id: 'user');
  final _ai = const types.User(id: 'ai', firstName: 'カウンセラー');
  bool _isAiTyping = false;

  @override
  void initState() {
    super.initState();
    final apiService = ref.read(apiServiceProvider);
    _graphDataFuture = _fetchAndBuildGraph(apiService);
    _addInitialChatMessage();
  }
  
  void _addInitialChatMessage() {
    // 画面を開いたときに最初のメッセージを追加
    final initialMessage = types.TextMessage(
      author: _ai,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: const Uuid().v4(),
      text: 'こんにちは。可視化されたご自身の思考のつながりについて、気になることや話してみたいことはありますか？',
    );
    setState(() {
      _messages.insert(0, initialMessage);
    });
  }

  Future<model.GraphData> _fetchAndBuildGraph(ApiService apiService) async {
    // ... (既存のグラフ取得処理、変更なし) ...
    try {
      final graphData = await apiService.getAnalysisGraph();
      
      if (!mounted) return graphData;

      _graph.nodes.clear();
      _graph.edges.clear();
      _nodeDataMap = { for (var v in graphData.nodes) v.id: v };

      final Map<String, Node> nodesForGraphView = {};
      for (var nodeData in graphData.nodes) {
        nodesForGraphView[nodeData.id] = Node.Id(nodeData.id);
        _graph.addNode(nodesForGraphView[nodeData.id]!);
      }

      for (var edgeData in graphData.edges) {
        final fromNode = nodesForGraphView[edgeData.source];
        final toNode = nodesForGraphView[edgeData.target];
        if (fromNode != null && toNode != null) {
          _graph.addEdge(
            fromNode,
            toNode,
            paint: Paint()
              ..color = Colors.grey.withOpacity(0.7)
              ..strokeWidth = edgeData.weight.toDouble().clamp(1.0, 8.0),
          );
        }
      }
      
      return graphData;
    } catch (e) {
      rethrow;
    }
  }

  // --- チャットメッセージ送信処理 ---
  Future<void> _handleSendPressed(types.PartialText message) async {
    final userMessage = types.TextMessage(
      author: _user,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: const Uuid().v4(),
      text: message.text,
    );

    setState(() {
      _messages.insert(0, userMessage);
      _isAiTyping = true; // AIが考え中であることを示す
    });

    try {
      final apiService = ref.read(apiServiceProvider);
      
      // バックエンドに送るためのチャット履歴を作成
      final historyForApi = _messages
          .where((m) => m is types.TextMessage)
          .map((m) => {
                'author': m.author.id,
                'text': (m as types.TextMessage).text,
              })
          .toList()
          .reversed // 古い順に並び替え
          .toList();

      final aiResponseText = await apiService.postChatMessage(
        chatHistory: historyForApi,
        message: message.text,
      );

      final aiMessage = types.TextMessage(
        author: _ai,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        text: aiResponseText,
      );

      setState(() {
        _messages.insert(0, aiMessage);
      });
    } catch (e) {
      final errorMessage = types.TextMessage(
        author: _ai,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        text: '申し訳ありません、エラーが発生しました。$e',
      );
      setState(() {
        _messages.insert(0, errorMessage);
      });
    } finally {
      setState(() {
        _isAiTyping = false; // AIの応答が完了
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // ... (既存のScaffoldとLayoutBuilder、変更なし) ...
    return Scaffold(
      appBar: AppBar(
        title: const Text('統合分析ダッシュボード'),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth > 800) {
            return _buildWideLayout();
          } else {
            return _buildNarrowLayout();
          }
        },
      ),
    );
  }

  // ... (既存の _buildGraphViewFuture, _buildWideLayout, _buildNarrowLayout, _buildGraphView, _buildNodeWidget, 変更なし) ...
  Widget _buildGraphViewFuture() {
    return FutureBuilder<model.GraphData>(
      future: _graphDataFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                '分析データの取得に失敗しました。\n\nエラー詳細:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        } else if (!snapshot.hasData || snapshot.data!.nodes.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Text(
                '分析できるデータがまだありません。\nセッションを完了すると、ここに思考の繋がりが可視化されます。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
            ),
          );
        } else {
          return _buildGraphView();
        }
      },
    );
  }

  Widget _buildWideLayout() {
    return Row(
      children: [
        Expanded(flex: 3, child: _buildGraphViewFuture()),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(flex: 2, child: _buildChatView()),
      ],
    );
  }

  Widget _buildNarrowLayout() {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            labelColor: Colors.black87,
            unselectedLabelColor: Colors.grey,
            indicatorColor: Colors.deepPurple,
            tabs: [
              Tab(text: 'グラフ分析', icon: Icon(Icons.auto_graph)),
              Tab(text: 'チャットで深掘り', icon: Icon(Icons.chat_bubble_outline)),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [_buildGraphViewFuture(), _buildChatView()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGraphView() {
    return InteractiveViewer(
      constrained: false,
      boundaryMargin: const EdgeInsets.all(200),
      minScale: 0.05,
      maxScale: 2.5,
      child: GraphView(
        graph: _graph,
        algorithm: _algorithm,
        paint: Paint()
          ..color = Colors.transparent
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
        builder: (Node node) {
          String nodeId = node.key!.value as String;
          final nodeData = _nodeDataMap[nodeId];
          return _buildNodeWidget(nodeData);
        },
      ),
    );
  }

  Widget _buildNodeWidget(model.Node? nodeData) {
    if (nodeData == null) {
      return const SizedBox.shrink();
    }

    final Map<String, Color> colorMap = {
      'emotion': Colors.orange.shade300,
      'topic': Colors.blue.shade300,
      'keyword': Colors.purple.shade200,
      'issue': Colors.red.shade300,
    };
    final color = colorMap[nodeData.type] ?? Colors.grey.shade400;

    return Tooltip(
      message: "${nodeData.id}\nタイプ: ${nodeData.type}",
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: color,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 3,
            )
          ],
        ),
        child: Text(
          nodeData.id,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
  // ↑↑↑ 置き換えここまで ↑↑↑
  
  // --- チャットUIのウィジェット ---
  Widget _buildChatView() {
    return Chat(
      messages: _messages,
      onSendPressed: _handleSendPressed,
      user: _user,
      theme: DefaultChatTheme(
        // チャットUIの見た目をカスタマイズ
        primaryColor: Colors.deepPurple,
        secondaryColor: Colors.grey.shade200,
        inputBackgroundColor: Colors.white,
        inputTextColor: Colors.black87,
        receivedMessageBodyTextStyle: const TextStyle(color: Colors.black87),
      ),
      // isTyping パラメータを typingIndicatorOptions に変更
      typingIndicatorOptions: TypingIndicatorOptions(
        typingUsers: _isAiTyping ? [_ai] : [],
      ),
      l10n: const ChatL10nEn(
        // 入力欄のプレースホルダーテキストを日本語化
        inputPlaceholder: 'メッセージを入力',
      ),
    );
  }
}