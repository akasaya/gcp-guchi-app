import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/graph_data.dart' as model;
import 'package:frontend/services/api_service.dart';
import 'package:frontend/models/chat_models.dart';
import 'package:graphview/GraphView.dart';
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:url_launcher/url_launcher.dart'; 
import 'package:uuid/uuid.dart';            

class AnalysisDashboardScreen extends ConsumerStatefulWidget {
  final NodeTapResponse? proactiveSuggestion;
  
  // ★★★ 修正点1: コンストラクタを修正 ★★★
  const AnalysisDashboardScreen({super.key, this.proactiveSuggestion});

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
  bool _isActionLoading = false;

  String? _lastActionMessageId;

  @override
  void initState() {
    super.initState();
    final apiService = ref.read(apiServiceProvider);
    _graphDataFuture = _fetchAndBuildGraph(apiService);
    if (widget.proactiveSuggestion != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleProactiveSuggestion(widget.proactiveSuggestion!);
      });
    } else {
      // なければ、通常の能動的提案を取得しにいく
      _addInitialMessage(apiService);
    }
  }

    Future<void> _handleProactiveSuggestion(NodeTapResponse suggestion) async {
    if (mounted) {
      // ★★★ 修正点2: nodeIdがnullでないことを確認 ★★★
      final nodeId = suggestion.nodeId;
      if (nodeId == null) {
        // もし万が一nodeIdが渡されなかった場合は、通常起動と同じにする
        _addInitialMessage(ref.read(apiServiceProvider));
        return;
      }

      // タップされたノードの情報を元に、深掘り分析を開始する
      // この時点ではグラフデータはまだないので、仮のNodeDataでOK
      _onNodeTapped(model.NodeData(
        id: nodeId,
        type: 'topic', // typeはグラフ描画時に正しいものに置き換わるので仮でOK
        size: 1,       // 同上
        label: suggestion.nodeLabel,
      ));


      // スマホ表示の場合はチャットタブに切り替える
      if (MediaQuery.of(context).size.width <= 800) {
        DefaultTabController.of(context)?.animateTo(1);
      }
    }
  }

  // ★★★ この関数を全面修正 ★★★
  Future<void> _addInitialMessage(ApiService apiService) async {
    // まずAIからの能動的な提案がないか確認する
    final suggestion = await apiService.getProactiveSuggestion();

    // 提案があった場合
    if (suggestion != null && mounted) {
      final actionMessageId = const Uuid().v4();
      final actionMessage = types.CustomMessage(
        author: _ai,
        id: actionMessageId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        metadata: {
          'text': suggestion.initialSummary,
          'actions': suggestion.actions.map((a) => {'id': a.id, 'label': a.label}).toList(),
          'node_label': suggestion.nodeLabel,
          'is_active': true,
        },
      );
      setState(() {
        _messages.insert(0, actionMessage);
        _lastActionMessageId = actionMessageId;
      });
      return; // 提案を表示したので、ここで処理を終了
    }

    // 提案がなかった場合、通常の初期メッセージを表示
    if (mounted) {
      final initialMessage = types.TextMessage(
        author: _ai,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        text: 'こんにちは。可視化されたご自身の思考のつながりについて、気になることや話してみたいことはありますか？\nグラフのキーワードをタップすると、そのテーマについて深掘りできます。',
      );
      setState(() => _messages.insert(0, initialMessage));
    }
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
          _graph.addEdge(fromNode, toNode, paint: Paint()..color = Colors.grey.withAlpha(150)..strokeWidth = edgeData.weight.clamp(0.5, 4.0));
        }
      }
      return graphData;
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _onNodeTapped(model.NodeData nodeData) async {
    if (_isActionLoading) return;
    setState(() => _isActionLoading = true);
    
    _disablePreviousActions();

    if (MediaQuery.of(context).size.width <= 800) {
      DefaultTabController.of(context).animateTo(1);
    }
    
    try {
      final apiService = ref.read(apiServiceProvider);
      // ★★★ 修正: .label を .id に変更 ★★★
      final response = await apiService.handleNodeTap(nodeData.id);

      final actionMessageId = const Uuid().v4();
      final actionMessage = types.CustomMessage(
        author: _ai,
        id: actionMessageId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        metadata: {
          'text': response.initialSummary,
          'actions': response.actions.map((a) => {'id': a.id, 'label': a.label}).toList(),
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

    setState(() => _isActionLoading = true);

    try {
        final apiService = ref.read(apiServiceProvider);
        final ragType = actionId == 'get_similar_cases' ? 'similar_cases' : 'suggestions';
        
        final historyForApi = _messages
          .whereType<types.TextMessage>()
          .map((m) => {'author': m.author.id, 'text': m.text})
          .toList().reversed.toList();

        final response = await apiService.postChatMessage(
          chatHistory: historyForApi,
          message: "$nodeLabel に関する${ragType == 'similar_cases' ? '類似ケース' : '改善案'}を教えてください。",
          useRag: true,
          ragType: ragType,
        );
        _addAiTextMessage(response.answer, sources: response.sources);
    } catch(e) {
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
          .toList().reversed.toList();

      final response = await apiService.postChatMessage(chatHistory: historyForApi, message: message.text);
      _addAiTextMessage(response.answer, sources: response.sources);
    } catch (e) {
      _addErrorMessage('エラーが発生しました: $e');
    } finally {
      setState(() => _isAiTyping = false);
    }
  }

  void _addHumanMessage(String text) {
    final userMessage = types.TextMessage(author: _user, createdAt: DateTime.now().millisecondsSinceEpoch, id: const Uuid().v4(), text: text);
    setState(() => _messages.insert(0, userMessage));
  }

  void _addAiTextMessage(String text, {List<String>? sources}) {
    final aiMessage = types.TextMessage(
      author: _ai,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      id: const Uuid().v4(),
      text: text,
      metadata: (sources != null && sources.isNotEmpty) ? {'sources': sources} : null,
    );
    setState(() => _messages.insert(0, aiMessage));
  }
  
  void _addErrorMessage(String text) {
      final errorMessage = types.TextMessage(author: _ai, createdAt: DateTime.now().millisecondsSinceEpoch, id: const Uuid().v4(), text: text);
      setState(() => _messages.insert(0, errorMessage));
  }

  void _disablePreviousActions() {
    if (_lastActionMessageId != null) {
      final lastIndex = _messages.indexWhere((m) => m.id == _lastActionMessageId);
      if (lastIndex != -1 && _messages[lastIndex] is types.CustomMessage) {
        final oldMessage = _messages[lastIndex] as types.CustomMessage;
        if (oldMessage.metadata?['is_active'] == true) {
            final newMetadata = Map<String, dynamic>.from(oldMessage.metadata ?? {});
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
        if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
        if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text('分析データの取得に失敗しました。\n\nエラー詳細:\n${snapshot.error}', textAlign: TextAlign.center)));
        if (!snapshot.hasData || snapshot.data!.nodes.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(16.0), child: Text('分析できるデータがまだありません。\nセッションを完了すると、ここに思考の繋がりが可視化されます。', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey))));
        return _buildGraphView();
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
          const TabBar(tabs: [Tab(text: 'グラフ分析', icon: Icon(Icons.auto_graph)), Tab(text: 'チャットで深掘り', icon: Icon(Icons.chat_bubble_outline))]),
          Expanded(child: TabBarView(children: [_buildGraphViewFuture(), _buildChatView()])),
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
        paint: Paint()..color = Colors.transparent..strokeWidth = 1..style = PaintingStyle.stroke,
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
    final Map<String, Color> colorMap = {'topic': Colors.purple.shade400, 'issue': Colors.red.shade400, 'emotion': Colors.orange.shade300, 'keyword': Colors.blueGrey.shade400};
    final nodeColor = colorMap[nodeData.type] ?? Colors.grey.shade400;
    return GestureDetector(
      onTap: () => _onNodeTapped(nodeData),
      child: Tooltip(
        // ★★★ 修正: .label を .id に変更 ★★★
        message: "${nodeData.id}\nタイプ: ${nodeData.type}",
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          constraints: const BoxConstraints(maxWidth: 150),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: nodeColor, boxShadow: [BoxShadow(color: Colors.black.withAlpha(51), blurRadius: 4, offset: const Offset(1, 1))]),
          // ★★★ 修正: .label を .id に変更 ★★★
          child: Text(nodeData.id, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
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
          secondaryColor: theme.colorScheme.surfaceContainerHighest,
          inputBackgroundColor: theme.colorScheme.surface,
          inputTextColor: theme.colorScheme.onSurface,
          receivedMessageBodyTextStyle: TextStyle(color: theme.colorScheme.onSurface),
          sentMessageBodyTextStyle: TextStyle(color: theme.colorScheme.onPrimary)),
      typingIndicatorOptions: TypingIndicatorOptions(typingUsers: _isAiTyping ? [_ai] : []),
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
    final sources = (message.metadata?['sources'] as List<dynamic>?)?.cast<String>();

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

  Widget _customMessageBuilder(types.CustomMessage message, {required int messageWidth}) {
    final metadata = message.metadata ?? {};
    final text = metadata['text'] as String?;
    final actionsData = metadata['actions'] as List<dynamic>?;
    final nodeLabel = metadata['node_label'] as String?;
    final isActive = metadata['is_active'] as bool? ?? false;

    if (text == null || actionsData == null || nodeLabel == null) {
      return const SizedBox.shrink();
    }
    
    final actions = actionsData.map((a) => ChatAction.fromJson(a as Map<String, dynamic>)).toList();
    
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
          SelectableText(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
          if (isActive) ...[
            const Divider(height: 20),
            ...actions.map((action) => Container(
                  margin: const EdgeInsets.only(top: 4),
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => _onActionTapped(action.id, nodeLabel),
                    child: Text(action.label),
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
          if (_isActionLoading) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: CircularProgressIndicator()),
          Input(
            isAttachmentUploading: _isActionLoading,
            onSendPressed: _handleSendPressed,
            options: const InputOptions(sendButtonVisibilityMode: SendButtonVisibilityMode.always),
          ),
        ],
      ),
    );
  }
}