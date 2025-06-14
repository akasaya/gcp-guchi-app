import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/graph_data.dart' as model; // graphviewのクラスと名前が衝突するのを防ぐ
import 'package:frontend/services/api_service.dart';
import 'package:graphview/GraphView.dart';

// Riverpodと連携するため、ConsumerStatefulWidgetに変更
class AnalysisDashboardScreen extends ConsumerStatefulWidget {
  const AnalysisDashboardScreen({super.key});

  @override
  ConsumerState<AnalysisDashboardScreen> createState() =>
      _AnalysisDashboardScreenState();
}

class _AnalysisDashboardScreenState extends ConsumerState<AnalysisDashboardScreen> {
  Future<model.GraphData>? _graphDataFuture;
  final Graph _graph = Graph();
  // ノード同士の配置を計算するアルゴリズム
  final Algorithm _algorithm = FruchtermanReingoldAlgorithm(iterations: 200);
  Map<String, model.Node> _nodeDataMap = {};


  @override
  void initState() {
    super.initState();
    // initState内でRiverpodからApiServiceのインスタンスを取得
    final apiService = ref.read(apiServiceProvider);
    // グラフデータを非同期で取得する処理を開始
    _graphDataFuture = _fetchAndBuildGraph(apiService);
  }

  Future<model.GraphData> _fetchAndBuildGraph(ApiService apiService) async {
    try {
      final graphData = await apiService.getAnalysisGraph();
      
      if (!mounted) return graphData;

      // グラフを再描画する前に、以前のデータをクリア
      _graph.nodes.clear();
      _graph.edges.clear();
      _nodeDataMap = { for (var v in graphData.nodes) v.id: v };

      // APIから取得したノードデータを、graphview用のNodeに変換
      final Map<String, Node> nodesForGraphView = {};
      for (var nodeData in graphData.nodes) {
        nodesForGraphView[nodeData.id] = Node.Id(nodeData.id);
        _graph.addNode(nodesForGraphView[nodeData.id]!);
      }

      // APIから取得したエッジデータを、graphview用のEdgeに変換
      for (var edgeData in graphData.edges) {
        final fromNode = nodesForGraphView[edgeData.source];
        final toNode = nodesForGraphView[edgeData.target];
        if (fromNode != null && toNode != null) {
          _graph.addEdge(
            fromNode,
            toNode,
            paint: Paint()
              ..color = Colors.grey.withOpacity(0.7)
              ..strokeWidth = edgeData.weight.toDouble().clamp(1.0, 8.0), // weightで線の太さを変える
          );
        }
      }
      
      return graphData;
    } catch (e) {
      // エラーが発生した場合、FutureBuilderに伝えるために再スローする
      rethrow;
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

  // FutureBuilderで非同期処理の状態を管理する
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
          // データ取得成功時にグラフを描画
          return _buildGraphView();
        }
      },
    );
  }

  // ワイドスクリーン用の左右分割レイアウト
  Widget _buildWideLayout() {
    return Row(
      children: [
        Expanded(flex: 3, child: _buildGraphViewFuture()),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(flex: 2, child: _buildChatView()),
      ],
    );
  }

  // ナロースクリーン用のタブ切り替えレイアウト
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

  // グラフを描画するウィジェット
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

  // 個々のノードを描画するウィジェット
  Widget _buildNodeWidget(model.Node? nodeData) {
    if (nodeData == null) {
      return const SizedBox.shrink();
    }

    // ノードのタイプに応じて色をマッピング
    final Map<String, Color> colorMap = {
      'emotion': Colors.orange.shade300,
      'topic': Colors.blue.shade300,
      'keyword': Colors.purple.shade200,
      'issue': Colors.red.shade300,
    };
    final color = colorMap[nodeData.type] ?? Colors.grey.shade400;
    
    // AIが指定したsizeに基づいて、表示上のサイズを計算
    final double visualSize = nodeData.size.toDouble().clamp(10.0, 30.0) * 4.5;

    return Tooltip(
      message: "${nodeData.id}\nタイプ: ${nodeData.type}",
      child: Container(
        width: visualSize,
        height: visualSize,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              spreadRadius: 1,
              blurRadius: 4,
            ),
          ],
        ),
        child: Center(
          child: Text(
            nodeData.id,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
            overflow: TextOverflow.fade,
          ),
        ),
      ),
    );
  }
  
  // チャットUI（今回は変更なし）
  Widget _buildChatView() {
    return Column(
      children: [
        const Expanded(
          child: Center(
            child: Text(
              'No messages here yet',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Message',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(icon: const Icon(Icons.send), onPressed: () {}),
            ],
          ),
        ),
      ],
    );
  }
}