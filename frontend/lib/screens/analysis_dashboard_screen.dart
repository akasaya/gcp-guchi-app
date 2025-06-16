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
  final Algorithm _algorithm = FruchtermanReingoldAlgorithm(iterations: 200);
  Map<String, model.NodeData> _nodeDataMap = {};
  final List<types.Message> _messages = [];
  final _user = const types.User(id: 'user');
  final _ai = const types.User(id: 'ai', firstName: 'AIアナリスト');
  bool _isAiTyping = false;

  @override
  void initState() {
    super.initState();
    final apiService = ref.read(apiServiceProvider);
    _graphDataFuture = _fetchAndBuildGraph(apiService);
    _addInitialChatMessage();

    // SugiyamaConfigurationの関連コードは不要になったため削除
  }

  void _addInitialChatMessage() {
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
              ..color = Colors.grey.withAlpha(150) // 少し薄くして見やすくする
              ..strokeWidth = edgeData.weight.clamp(0.5, 4.0), // 線を少し細くする
          );
        }
      }
      return graphData;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _handleSendPressed(types.PartialText message) async {
    final userMessage = types.TextMessage(
      author: _user,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: const Uuid().v4(),
      text: message.text,
    );

    setState(() {
      _messages.insert(0, userMessage);
      _isAiTyping = true;
    });

    try {
      final apiService = ref.read(apiServiceProvider);
      final historyForApi = _messages
          .whereType<types.TextMessage>()
          .map((m) => {
                // バックエンドの仕様に合わせてキーを元に戻します
                'author': m.author.id,
                'text': m.text,
              })
          .toList()
          .reversed
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
        _isAiTyping = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
      boundaryMargin: const EdgeInsets.all(100),
      minScale: 0.05,
      maxScale: 2.5,
      child: GraphView(
        graph: _graph,
        algorithm: _algorithm, // 新しいアルゴリズムを適用
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

  Widget _buildNodeWidget(model.NodeData? nodeData) {
    if (nodeData == null) {
      return const SizedBox.shrink();
    }

    // --- ↓↓↓ ここからが修正箇所です ↓↓↓ ---
    // ノードの種類に応じて色を決定するマップ
    final Map<String, Color> colorMap = {
      'topic': Colors.purple.shade400,
      'issue': Colors.red.shade400,
      'emotion': Colors.orange.shade300,
      'keyword': Colors.blueGrey.shade400,
    };
    // マップから色を取得し、なければデフォルト色（グレー）を使用
    final nodeColor = colorMap[nodeData.type] ?? Colors.grey.shade400;

    return Tooltip(
      message: "${nodeData.label}\nタイプ: ${nodeData.type}",
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: nodeColor, // ★★★ 決定した色を使用 ★★★
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 4,
              offset: const Offset(1, 1),
            )
          ],
        ),
        child: Text(
          nodeData.label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildChatView() {
    // --- ↓↓↓ ここからが修正箇所です ↓↓↓ ---
    return Stack(
      children: [
        Chat(
          messages: _messages,
          onSendPressed: _handleSendPressed,
          user: _user,
          theme: DefaultChatTheme(
            primaryColor: Colors.deepPurple,
            secondaryColor: Colors.grey.shade200,
            inputBackgroundColor: Colors.white,
            inputTextColor: Colors.black87,
            receivedMessageBodyTextStyle: const TextStyle(color: Colors.black87),
          ),
          typingIndicatorOptions: TypingIndicatorOptions(
            typingUsers: _isAiTyping ? [_ai] : [],
          ),
          l10n: const ChatL10nEn(
            inputPlaceholder: 'メッセージを入力',
          ),
        ),
        // RAGを呼び出すための「改善案」ボタン
        Positioned(
          bottom: 16,
          right: 16,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.lightbulb_outline),
            label: const Text('改善案を教えて'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              shape: const StadiumBorder(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onPressed: () {
              // ボタンが押されたら、特定のメッセージを送信する
              _handleSendPressed(
                types.PartialText(text: 'RAGを使って具体的な改善案を教えてください。')
              );
            },
          ),
        )
      ],
    );
    // --- ↑↑↑ 追加はここまでです ↑↑↑ ---
  }
}