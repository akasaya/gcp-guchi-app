import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/graph_data.dart' as model;
import 'package:frontend/services/api_service.dart';
import 'package:graphview/GraphView.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:url_launcher/url_launcher.dart';
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
  bool _isRagLoading = false;

  @override
  void initState() {
    super.initState();
    final apiService = ref.read(apiServiceProvider);
    _graphDataFuture = _fetchAndBuildGraph(apiService);
    _addInitialChatMessage();
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
              ..color = Colors.grey.withAlpha(150)
              ..strokeWidth = edgeData.weight.clamp(0.5, 4.0),
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
          .map((m) => {'author': m.author.id, 'text': m.text})
          .toList()
          .reversed
          .toList();

      // ★★★ ステップ1の修正箇所 ★★★
      final response = await apiService.postChatMessage(
        chatHistory: historyForApi,
        message: message.text,
      );

      final aiMessage = types.TextMessage(
        author: _ai,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        text: response.answer,
        metadata: response.sources.isNotEmpty ? {'sources': response.sources} : null,
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

  Future<void> _handleRagRequest() async {
    setState(() => _isRagLoading = true);

    final thinkingMessage = types.TextMessage(
      author: _ai,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: const Uuid().v4(),
      text: 'あなたに合った具体的な改善案を探しています... 少々お待ちください。',
    );
    setState(() => _messages.insert(0, thinkingMessage));

    try {
      final apiService = ref.read(apiServiceProvider);
      final historyForApi = _messages
          .where((m) => m is types.TextMessage && m.id != thinkingMessage.id)
          .map((m) {
            final textMessage = m as types.TextMessage;
            return {'author': m.author.id, 'text': textMessage.text};
          })
          .toList()
          .reversed
          .toList();

      final response = await apiService.postChatMessage(
        chatHistory: historyForApi,
        message: "RAGを使って具体的な改善案を教えてください。",
        useRag: true,
      );

      final aiMessage = types.TextMessage(
        author: _ai,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        text: response.answer,
        metadata: response.sources.isNotEmpty ? {'sources': response.sources} : null,
      );

      setState(() {
        _messages.removeAt(0);
        _messages.insert(0, aiMessage);
      });
    } catch (e) {
      setState(() {
        _messages.removeAt(0);
        final errorMessage = types.TextMessage(
          author: _ai,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          id: const Uuid().v4(),
          text: '申し訳ありません、改善案の取得中にエラーが発生しました。$e',
        );
        _messages.insert(0, errorMessage);
      });
    } finally {
      setState(() => _isRagLoading = false);
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
          return Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text('分析データの取得に失敗しました。\n\nエラー詳細:\n${snapshot.error}', textAlign: TextAlign.center)));
        } else if (!snapshot.hasData || snapshot.data!.nodes.isEmpty) {
          return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: Text('分析できるデータがまだありません。\nセッションを完了すると、ここに思考の繋がりが可視化されます。', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey))));
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

  Widget _buildNodeWidget(model.NodeData? nodeData) {
    if (nodeData == null) return const SizedBox.shrink();
    final Map<String, Color> colorMap = {
      'topic': Colors.purple.shade400,
      'issue': Colors.red.shade400,
      'emotion': Colors.orange.shade300,
      'keyword': Colors.blueGrey.shade400,
    };
    final nodeColor = colorMap[nodeData.type] ?? Colors.grey.shade400;
    return Tooltip(
      message: "${nodeData.label}\nタイプ: ${nodeData.type}",
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: nodeColor,
          boxShadow: [BoxShadow(color: Colors.black.withAlpha(51), blurRadius: 4, offset: const Offset(1, 1))],
        ),
        child: Text(
          nodeData.label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _buildChatView() {
    final theme = Theme.of(context);
    return Chat(
      messages: _messages,
      onSendPressed: _handleSendPressed,
      user: _user,
      theme: DefaultChatTheme(
        primaryColor: theme.colorScheme.primary,
        // ★★★ 修正点1: 非推奨の `surfaceVariant` を `surfaceContainerHighest` に変更
        secondaryColor: theme.colorScheme.surfaceContainerHighest,
        inputBackgroundColor: theme.colorScheme.surface,
        inputTextColor: theme.colorScheme.onSurface,
        // ★★★ 修正点1: 上記の変更に合わせて文字色も `onSurface` に変更
        receivedMessageBodyTextStyle: TextStyle(color: theme.colorScheme.onSurface),
        sentMessageBodyTextStyle: TextStyle(color: theme.colorScheme.onPrimary),
      ),
      typingIndicatorOptions: TypingIndicatorOptions(
        typingUsers: _isAiTyping ? [_ai] : [],
      ),
      l10n: const ChatL10nEn(
        inputPlaceholder: 'メッセージを入力',
      ),
      customBottomWidget: _buildChatInputArea(),
      textMessageBuilder: _textMessageBuilder,
    );
  }

  Widget _textMessageBuilder(
    types.TextMessage message, {
    required int messageWidth,
    required bool showName,
  }) {
    final materialTheme = Theme.of(context);
    final bool isMe = message.author.id == _user.id;
    final sources = (message.metadata?['sources'] as List<dynamic>?)?.cast<String>();

    final textStyle = isMe
        ? TextStyle(color: materialTheme.colorScheme.onPrimary)
        : TextStyle(color: materialTheme.colorScheme.onSurface);
    
    final linkColor = isMe ? Colors.white70 : Colors.blue.shade800;

    // メッセージの「吹き出し」を表現するContainer
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        // 自分と相手で色分け
        color: isMe
            ? materialTheme.colorScheme.primary
            : materialTheme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      // 吹き出しの幅を適切に制限する
      constraints: BoxConstraints(
        maxWidth: messageWidth * 0.75,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, // 吹き出しの中身は常に左揃え
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            message.text,
            style: textStyle,
          ),
          if (sources != null && sources.isNotEmpty) ...[
            const Divider(height: 16),
            Text(
              '参考情報',
              style: textStyle.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            ...sources.map((source) {
              return InkWell(
                onTap: () async {
                  final uri = Uri.parse(source);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri);
                  }
                },
                child: Text(
                  source,
                  style: textStyle.copyWith(
                    decoration: TextDecoration.underline,
                    color: linkColor,
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildChatInputArea() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
           ElevatedButton.icon(
              icon: _isRagLoading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.lightbulb_outline),
              label: const Text('具体的な改善案を聞く'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                minimumSize: const Size(double.infinity, 48)
              ),
              onPressed: _isRagLoading ? null : _handleRagRequest,
            ),
          const SizedBox(height: 8),
          Input(
            onSendPressed: _handleSendPressed,
            options: const InputOptions(
              sendButtonVisibilityMode: SendButtonVisibilityMode.always,
            ),
          ),
        ],
      ),
    );
  }
}