import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/book_recommendation.dart';
import 'package:frontend/models/graph_data.dart' as model;
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:graphview/GraphView.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart'; 

class _KeepAliveGraphView extends StatefulWidget {
  final Graph graph;
  final Algorithm algorithm;
  final Map<String, model.NodeData> nodeDataMap;
  final Function(model.NodeData) onNodeTapped;
  final int maxNodeSize;

  const _KeepAliveGraphView({
    required this.graph,
    required this.algorithm,
    required this.nodeDataMap,
    required this.onNodeTapped,
    required this.maxNodeSize,
  });

  @override
  __KeepAliveGraphViewState createState() => __KeepAliveGraphViewState();
}

class __KeepAliveGraphViewState extends State<_KeepAliveGraphView>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return InteractiveViewer(
      constrained: false,
      boundaryMargin: const EdgeInsets.all(200),
      minScale: 0.05,
      maxScale: 4.0,
      child: GraphView(
        graph: widget.graph,
        algorithm: widget.algorithm,
        paint: Paint()
          ..color = Colors.grey
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
        builder: (Node node) {
          String nodeId = node.key!.value as String;
          final nodeData = widget.nodeDataMap[nodeId];
          return _buildNodeWidget(nodeData);
        },
      ),
    );
  }

  Widget _buildNodeWidget(model.NodeData? nodeData) {
    if (nodeData == null) return const SizedBox.shrink();

    const double minDiameter = 60.0;
    const double maxDiameter = 150.0;
    final double normalizedSize = widget.maxNodeSize == 0
        ? 0
        : (nodeData.size / widget.maxNodeSize).clamp(0.0, 1.0);
    final double diameter =
        minDiameter + (maxDiameter - minDiameter) * normalizedSize;
    final double fontSize = 12 + (6 * normalizedSize);

    final Map<String, Color> colorMap = {
      'topic': Colors.purple.shade400,
      'issue': Colors.red.shade400,
      'emotion': Colors.orange.shade300,
      'keyword': Colors.blueGrey.shade400
    };
    final nodeColor = colorMap[nodeData.type] ?? Colors.grey.shade400;

    return GestureDetector(
      onTap: () => widget.onNodeTapped(nodeData),
      child: Tooltip(
        message:
            "${nodeData.id}\nタイプ: ${nodeData.type}\n重要度: ${nodeData.size}",
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: nodeColor,
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withAlpha(51),
                  blurRadius: 4,
                  offset: const Offset(1, 1))
            ],
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                nodeData.id,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: fontSize,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AnalysisDashboardScreen extends ConsumerStatefulWidget {
  final NodeTapResponse? proactiveSuggestion;

  const AnalysisDashboardScreen({super.key, this.proactiveSuggestion});

  @override
  ConsumerState<AnalysisDashboardScreen> createState() =>
      _AnalysisDashboardScreenState();
}

class _AnalysisDashboardScreenState
    extends ConsumerState<AnalysisDashboardScreen> with TickerProviderStateMixin {
  Future<model.GraphData>? _graphDataFuture;
  late Future<AnalysisSummary> _summaryFuture;
  late Future<List<BookRecommendation>> _bookRecommendationsFuture;
  final Graph _graph = Graph();
  final Algorithm _algorithm = SugiyamaAlgorithm(SugiyamaConfiguration()
    ..levelSeparation = 150
    ..nodeSeparation = 15
    ..orientation = SugiyamaConfiguration.ORIENTATION_TOP_BOTTOM);

  Map<String, model.NodeData> _nodeDataMap = {};
  int _maxNodeSize = 1; 

  final List<types.Message> _messages = [];
  final _user = const types.User(id: 'user');
  final _ai = const types.User(id: 'ai', firstName: 'AIアナリスト');
  bool _isAiTyping = false;
  bool _isActionLoading = false;
  late TabController _narrowTabController;
  late TabController _wideTabController;

  StreamSubscription<DocumentSnapshot>? _ragSubscription;
  String? _lastActionMessageId;


  @override
  void initState() {
    super.initState();
    final apiService = ref.read(apiServiceProvider);
    _graphDataFuture = _fetchAndBuildGraph(apiService);
    _summaryFuture = apiService.getAnalysisSummary();
    _bookRecommendationsFuture = apiService.getBookRecommendations();

    _narrowTabController = TabController(length: 4, vsync: this); // 3から4へ変更
    _wideTabController = TabController(length: 3, vsync: this);   // 2から3へ変更

    if (widget.proactiveSuggestion != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleProactiveSuggestion(widget.proactiveSuggestion!);
      });
    } else {
      _addInitialMessage();
    }
  }

  @override
  void dispose() {
    _narrowTabController.dispose();
    _wideTabController.dispose();
    _ragSubscription?.cancel();
    super.dispose();
  }

  void _addInitialMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _messages.isEmpty) {
        final initialMessage = types.TextMessage(
          author: _ai,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          id: const Uuid().v4(),
          text:
              'こんにちは。ここでは、あなたの思考を可視化したグラフ全体について、AIと対話しながら更に深く探求できます。\n\nグラフ上のキーワードをタップすると、そのテーマに関する詳しい情報を見たり、関連する対話を始めたりできます。もちろん、このまま自由にメッセージを送っていただくことも可能です。',
        );
        setState(() {
          _messages.insert(0, initialMessage);
        });
      }
    });
  }

  Future<void> _handleProactiveSuggestion(NodeTapResponse suggestion) async {
    if (mounted) {
      final nodeId = suggestion.nodeId;
      if (nodeId == null) {
        _addInitialMessage();
        return;
      }
      _onNodeTapped(model.NodeData(
        id: nodeId,
        type: 'topic',
        size: 1,
        label: suggestion.nodeLabel,
      ));

      if (MediaQuery.of(context).size.width <= 900) {
        _narrowTabController.animateTo(2);
      }
    }
  }

  Future<model.GraphData> _fetchAndBuildGraph(ApiService apiService) async {
    try {
      final graphData = await apiService.getAnalysisGraph();
      if (!mounted) return graphData;

      _graph.nodes.clear();
      _graph.edges.clear();
      _nodeDataMap = {for (var v in graphData.nodes) v.id: v};

      if (graphData.nodes.isNotEmpty) {
        _maxNodeSize = graphData.nodes.map((n) => n.size).reduce(max);
        if (_maxNodeSize == 0) _maxNodeSize = 1;
      }

      final Map<String, Node> nodesForGraphView = {};
      for (var nodeData in graphData.nodes) {
        nodesForGraphView[nodeData.id] = Node.Id(nodeData.id);
        _graph.addNode(nodesForGraphView[nodeData.id]!);
      }

      for (var edgeData in graphData.edges) {
        final fromNode = nodesForGraphView[edgeData.source];
        final toNode = nodesForGraphView[edgeData.target];
        if (fromNode != null && toNode != null) {
          _graph.addEdge(fromNode, toNode,
              paint: Paint()
                ..color = Colors.grey.withAlpha(150)
                ..strokeWidth = edgeData.weight.clamp(0.5, 4.0));
        }
      }
      return graphData;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _onNodeTapped(model.NodeData nodeData) async {
    if (_isActionLoading) return;

    _addHumanMessage(nodeData.id);

    setState(() => _isActionLoading = true);

    _disablePreviousActions();

    if (MediaQuery.of(context).size.width <= 900) {
      _narrowTabController.animateTo(2); 
    } else {
      _wideTabController.animateTo(0);
    }

    try {
      final apiService = ref.read(apiServiceProvider);
      final response = await apiService.handleNodeTap(nodeData.id);

      final actionMessageId = const Uuid().v4();
      final actionMessage = types.CustomMessage(
        author: _ai,
        id: actionMessageId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        metadata: {
          'text': response.initialSummary,
          'actions': response.actions
              .map((a) => {'id': a.id, 'title': a.title})
              .toList(),
          'node_label': response.nodeLabel,
          'is_active': true,
        },
      );
      setState(() {
        _messages.insert(0, actionMessage);
        _lastActionMessageId = actionMessageId;
      });
    } catch (e) {
      _addErrorMessage('ノード情報の取得中にエラーが発生しました: $e');
    } finally {
      setState(() => _isActionLoading = false);
    }
  }

  Future<void> _onActionTapped(String actionId, String nodeLabel) async {
    if (_isActionLoading) return;
    _disablePreviousActions();

    if (actionId == 'talk_freely') {
      return;
    }

    await _ragSubscription?.cancel();
    _ragSubscription = null;

    setState(() => _isActionLoading = true);

    try {
      final apiService = ref.read(apiServiceProvider);
      final ragType = actionId;

      final historyForApi = _messages
          .whereType<types.TextMessage>()
          .map((m) => {'author': m.author.id, 'text': m.text})
          .toList()
          .reversed
          .toList();

      // 1. RAGの開始を依頼し、中間応答とrequestIdを取得
      final initialResponse = await apiService.postChatMessage(
        chatHistory: historyForApi,
        message:
            "$nodeLabel に関する${ragType == 'similar_cases' ? '類似ケース' : '改善案'}を教えてください。",
        useRag: true,
        ragType: ragType,
      );

      // 2. 中間応答をチャットに追加
      _addAiTextMessage(initialResponse.response);

      // 3. requestId を使ってFirestoreのドキュメントを監視
      if (initialResponse.requestId != null) {
        final docRef = FirebaseFirestore.instance
            .collection('rag_responses')
            .doc(initialResponse.requestId);
        
        _ragSubscription = docRef.snapshots().listen((snapshot) async {
          if (snapshot.exists) {
            final status = snapshot.data()?['status'];
            if (status == 'completed') {
              final data = snapshot.data()!;
              final finalResponse = ChatResponse.fromJson(data);
              
              _addAiTextMessage(finalResponse.response, sources: finalResponse.sources);
              
              // 監視を終了
              await _ragSubscription?.cancel();
              _ragSubscription = null;

            } else if (status == 'error') {
              _addErrorMessage('情報の取得中にバックエンドでエラーが発生しました。');

              // 監視を終了
              await _ragSubscription?.cancel();
              _ragSubscription = null;
            }
          }
        });
      }
    } catch (e) {
      _addErrorMessage('情報の取得中にエラーが発生しました: $e');
    } finally {
      setState(() => _isActionLoading = false);
    }
  }

  Future<void> _handleSendPressed(types.PartialText message) async {
    if (_isActionLoading) return;
    _disablePreviousActions();
    _addHumanMessage(message.text);
    setState(() => _isAiTyping = true);

    try {
      final apiService = ref.read(apiServiceProvider);
      final historyForApi = _messages
          .whereType<types.TextMessage>()
          .map((m) => {'author': m.author.id, 'text': m.text})
          .toList()
          .reversed
          .toList();

      final response = await apiService.postChatMessage(
          chatHistory: historyForApi, message: message.text);
      _addAiTextMessage(response.response, sources: response.sources);
    } catch (e) {
      _addErrorMessage('エラーが発生しました: $e');
    } finally {
      setState(() => _isAiTyping = false);
    }
  }

  void _addHumanMessage(String text) {
    final userMessage = types.TextMessage(
        author: _user,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        text: text);
    setState(() => _messages.insert(0, userMessage));
  }

  void _addAiTextMessage(String text, {List<String>? sources}) {
    final aiMessage = types.TextMessage(
      author: _ai,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: const Uuid().v4(),
      text: text,
      metadata:
          (sources != null && sources.isNotEmpty) ? {'sources': sources} : null,
    );
    setState(() => _messages.insert(0, aiMessage));
  }

  void _addErrorMessage(String text) {
    final errorMessage = types.TextMessage(
        author: _ai,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        text: text);
    setState(() => _messages.insert(0, errorMessage));
  }

  void _disablePreviousActions() {
    if (_lastActionMessageId != null) {
      final lastIndex =
          _messages.indexWhere((m) => m.id == _lastActionMessageId);
      if (lastIndex != -1 && _messages[lastIndex] is types.CustomMessage) {
        final oldMessage = _messages[lastIndex] as types.CustomMessage;
        if (oldMessage.metadata?['is_active'] == true) {
          final newMetadata =
              Map<String, dynamic>.from(oldMessage.metadata ?? {});
          newMetadata['is_active'] = false;
          final updatedMessage = oldMessage.copyWith(metadata: newMetadata);
          setState(() => _messages[lastIndex] = updatedMessage);
        }
      }
      _lastActionMessageId = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('統合分析ダッシュボード')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth > 900) {
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
        }
        if (snapshot.hasError) {
          return Center(child: Text('エラー: ${snapshot.error}'));
        }
        if (!snapshot.hasData || snapshot.data!.nodes.isEmpty) {
          return const Center(child: Text('分析データがまだありません。'));
        }

        // ★★★ 修正1: 凡例をボタンによるダイアログ表示に変更 ★★★
        return Stack(
          children: [
            _KeepAliveGraphView(
              graph: _graph,
              algorithm: _algorithm,
              nodeDataMap: _nodeDataMap,
              onNodeTapped: _onNodeTapped,
              maxNodeSize: _maxNodeSize,
            ),
            Positioned(
              top: 16,
              right: 16,
              child: FloatingActionButton.small(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('凡例'),
                      content: _buildLegendContent(),
                      actions: [
                        TextButton(
                          child: const Text('閉じる'),
                          onPressed: () => Navigator.of(context).pop(),
                        )
                      ],
                    ),
                  );
                },
                tooltip: '凡例を表示',
                child: const Icon(Icons.help_outline),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildLegendContent() {
    final legendData = {
      '主要トピック': Colors.purple.shade400,
      '課題・悩み': Colors.red.shade400,
      '感情': Colors.orange.shade300,
      '関連キーワード': Colors.blueGrey.shade400,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: legendData.entries.map((entry) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4.0),
          child: Row(
            children: [
              Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: entry.value,
                ),
              ),
              const SizedBox(width: 8),
              Text(entry.key),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildWideLayout() {
    return Row(
      children: [
        Expanded(flex: 3, child: _buildGraphViewFuture()),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          flex: 2,
          child: Column(
            children: [
              TabBar(
                controller: _wideTabController,
                tabs: const [
                  Tab(
                      text: 'チャットで深掘り',
                      icon: Icon(Icons.chat_bubble_outline)),
                  Tab(text: '統計サマリー', icon: Icon(Icons.bar_chart_outlined)),
                  Tab(text: 'おすすめ書籍', icon: Icon(Icons.book_outlined)),
                ],
              ),
              Expanded(
                child: TabBarView(
                  controller: _wideTabController,
                  children: [
                    _buildChatView(),
                    _buildSummaryView(),
                    _buildBookRecommendationsView(), // 新しいメソッドを呼び出し
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNarrowLayout() {
    return Column(
      children: [
        TabBar(
          controller: _narrowTabController,
          tabs: const [
            Tab(text: 'サマリー', icon: Icon(Icons.bar_chart_outlined)),
            Tab(text: 'グラフ分析', icon: Icon(Icons.auto_graph)),
            Tab(text: 'チャット', icon: Icon(Icons.chat_bubble_outline)),
            Tab(text: '書籍', icon: Icon(Icons.book_outlined)),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _narrowTabController,
            children: [
              _buildSummaryView(),
              _buildGraphViewFuture(),
              _buildChatView(),
              _buildBookRecommendationsView(), // 新しいメソッドを呼び出し
            ],
          ),
        ),
      ],
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
          secondaryColor: theme.colorScheme.surfaceContainerHighest,
          inputBackgroundColor: theme.colorScheme.surface,
          inputTextColor: theme.colorScheme.onSurface,
          receivedMessageBodyTextStyle:
              TextStyle(color: theme.colorScheme.onSurface),
          sentMessageBodyTextStyle:
              TextStyle(color: theme.colorScheme.onPrimary)),
      typingIndicatorOptions:
          TypingIndicatorOptions(typingUsers: _isAiTyping ? [_ai] : []),
      l10n: const ChatL10nEn(inputPlaceholder: 'メッセージを入力'),
      customBottomWidget: _buildChatInputArea(),
      customMessageBuilder: _customMessageBuilder,
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
    final sources =
        (message.metadata?['sources'] as List<dynamic>?)?.cast<String>();

    final textStyle = isMe
        ? TextStyle(color: materialTheme.colorScheme.onPrimary)
        : TextStyle(color: materialTheme.colorScheme.onSurface);

    final linkColor = isMe ? Colors.white70 : Colors.blue.shade800;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isMe
            ? materialTheme.colorScheme.primary
            : materialTheme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      constraints: BoxConstraints(
        maxWidth: messageWidth * 0.75,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
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

  Widget _customMessageBuilder(types.CustomMessage message,
      {required int messageWidth}) {
    final metadata = message.metadata ?? {};
    final text = metadata['text'] as String?;
    final actionsData = metadata['actions'] as List<dynamic>?;
    final nodeLabel = metadata['node_label'] as String?;
    final isActive = metadata['is_active'] as bool? ?? false;

    if (text == null || actionsData == null || nodeLabel == null) {
      return const SizedBox.shrink();
    }

    final actions = actionsData
        .map((a) => ChatAction.fromJson(a as Map<String, dynamic>))
        .toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      constraints: BoxConstraints(maxWidth: messageWidth * 0.85),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(text,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
          if (isActive) ...[
            const Divider(height: 20),
            ...actions.map((action) => Container(
                  margin: const EdgeInsets.only(top: 4),
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => _onActionTapped(action.id, nodeLabel),
                    child: Text(action.title),
                  ),
                )),
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
          if (_isActionLoading)
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: CircularProgressIndicator()),
          Input(
            isAttachmentUploading: _isActionLoading,
            onSendPressed: _handleSendPressed,
            options: const InputOptions(
                sendButtonVisibilityMode: SendButtonVisibilityMode.always),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryView() {
    return FutureBuilder<AnalysisSummary>(
      future: _summaryFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        } else if (snapshot.hasError) {
          return Center(
              child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('エラーが発生しました: ${snapshot.error}',
                textAlign: TextAlign.center),
          ));
        } else if (!snapshot.hasData || snapshot.data!.totalSessions == 0) {
          return const Center(
              child: Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('分析できる記録がまだありません。', textAlign: TextAlign.center),
          ));
        }

        final summary = snapshot.data!;
        final allTopics = summary.topicCounts
          ..sort((a, b) => b.count.compareTo(a.count));
        final topTopics = allTopics.take(3).toList();

        return RefreshIndicator(
          onRefresh: () async {
            setState(() {
              _summaryFuture = ref.read(apiServiceProvider).getAnalysisSummary();
              _bookRecommendationsFuture =
                  ref.read(apiServiceProvider).getBookRecommendations();
            });
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummaryCard(
                    '総セッション回数',
                    '${summary.totalSessions} 回',
                    Icons.history,
                    Colors.blue,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'テーマ別対話回数',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 250,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: _buildTopicPieChart(allTopics),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'よく考えているテーマ Top 3',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  if (topTopics.isEmpty)
                    const Card(
                      child: ListTile(
                        title: Text('記録がありません'),
                      ),
                    )
                  else
                    Card(
                      child: Column(
                        children: topTopics.asMap().entries.map((entry) {
                          int idx = entry.key;
                          TopicCount topic = entry.value;
                          return ListTile(
                            leading: CircleAvatar(
                              child: Text('${idx + 1}'),
                            ),
                            title: Text(topic.topic),
                            trailing: Text('${topic.count} 回'),
                          );
                        }).toList(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopicPieChart(List<TopicCount> counts) {
    if (counts.isEmpty) return const Center(child: Text("データがありません"));

    final List<PieChartSectionData> sections = [];
    final List<TopicCount> dataForChart;
    const int topN = 5;

    final totalCount = counts.map((c) => c.count).reduce((a, b) => a + b);

    if (totalCount == 0) return const Center(child: Text("データがありません"));

    if (counts.length > topN) {
      dataForChart = counts.take(topN).toList();
      final othersCount =
          counts.skip(topN).map((c) => c.count).reduce((a, b) => a + b);
      if (othersCount > 0) {
        dataForChart.add(TopicCount(topic: 'その他', count: othersCount));
      }
    } else {
      dataForChart = counts;
    }

    for (int i = 0; i < dataForChart.length; i++) {
      final data = dataForChart[i];
      final isTouched = false;
      const fontSize = 12.0;
      const radius = 50.0;
      final value = (data.count / totalCount * 100);

      if (value < 1) continue; // 小さすぎるデータは表示しない

      sections.add(PieChartSectionData(
        color: Colors.primaries[i % Colors.primaries.length],
        value: value,
        title: '${value.toStringAsFixed(0)}%',
        radius: radius,
        titleStyle: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: const [Shadow(color: Colors.black, blurRadius: 2)]),
      ));
    }

    return Row(
      children: <Widget>[
        Expanded(
          flex: 2,
          child: PieChart(
            PieChartData(
              pieTouchData: null,
              borderData: FlBorderData(show: false),
              sectionsSpace: 2,
              centerSpaceRadius: 40,
              sections: sections,
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child: ListView.builder(
            itemCount: dataForChart.length,
            itemBuilder: (context, i) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      color: Colors.primaries[i % Colors.primaries.length],
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                        child: Text(
                      dataForChart[i].topic,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    )),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }


  Widget _buildBookRecommendations() {
    return FutureBuilder<List<BookRecommendation>>(
      future: _bookRecommendationsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('書籍の推薦取得に失敗しました: ${snapshot.error}'));
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.menu_book_outlined),
              title: Text('あなたへのおすすめはまだありません'),
              subtitle: Text('対話を進めると、AIが書籍を推薦します'),
            ),
          );
        }

        final recommendations = snapshot.data!;
        // ★★★ 修正: ListView.builderをColumnに変更し、警告を解消します ★★★
        return Column(
          children: recommendations.map((book) {
            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      book.author,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Divider(height: 20),
                    Text(
                      book.reason,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.search),
                        label: const Text('この本を探す'),
                        onPressed: () async {
                          final uri = Uri.parse(book.searchUrl);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }


  Widget _buildSummaryCard(
      String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 2.0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Row(
          children: [
            Icon(icon, size: 40, color: color),
            const SizedBox(width: 20),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  value,
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold, color: color),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookRecommendationsView() {
    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          _bookRecommendationsFuture =
              ref.read(apiServiceProvider).getBookRecommendations();
        });
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: _buildBookRecommendations(),
        ),
      ),
    );
  }
}