import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import 'package:graphview/GraphView.dart'; // 新しいライブラリをインポート

import '../models/graph_data.dart' as app_graph;
import '../services/api_service.dart';

// Providerの定義 (変更なし)
final graphDataProvider = FutureProvider<app_graph.GraphData>((ref) {
  final apiService = ref.watch(apiServiceProvider);
  return apiService.getAnalysisGraph();
});

class AnalysisDashboardScreen extends ConsumerWidget {
  const AnalysisDashboardScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncGraphData = ref.watch(graphDataProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('統合分析ダッシュボード'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
      ),
      body: Center(
        child: asyncGraphData.when(
          loading: () => _buildLoadingState(context),
          error: (err, stack) => _buildErrorState(context, err, ref),
          data: (graphData) {
            if (graphData.nodes.isEmpty) {
              return _buildEmptyState(context, ref);
            }

            // 1. 新しいライブラリ用のGraphオブジェクトを作成
            final graph = Graph();
            // ★★★【コンパイルエラーの修正】★★★
            // このライブラリのFruchtermanReingoldAlgorithmは、
            // iterations以外のパラメータをコンストラクタで取りません。
            // 不要なパラメータを削除しました。
            final algorithm = FruchtermanReingoldAlgorithm(
              iterations: 200,
            );

            // 2. Mapを使って、後からエッジを追加できるようにノードを保存
            final Map<String, Node> nodeMap = {};
            for (var nodeData in graphData.nodes) {
              final node = Node.Id(nodeData.id);
              nodeMap[nodeData.id] = node;
              graph.addNode(node);
            }

            // 3. 保存したノードを使ってエッジを追加
            for (var edgeData in graphData.edges) {
              final sourceNode = nodeMap[edgeData.source];
              final targetNode = nodeMap[edgeData.target];
              if (sourceNode != null && targetNode != null) {
                graph.addEdge(
                  sourceNode,
                  targetNode,
                  paint: Paint()
                    ..color = Colors.grey
                    ..strokeWidth = edgeData.weight.clamp(1, 10).toDouble() / 2.0,
                );
              }
            }

            // 4. GraphViewウィジェットを返す
            return InteractiveViewer(
              constrained: false,
              boundaryMargin: const EdgeInsets.all(100),
              minScale: 0.01,
              maxScale: 5.6,
              child: GraphView(
                graph: graph,
                algorithm: algorithm,
                paint: Paint()
                  ..color = Colors.green
                  ..strokeWidth = 1
                  ..style = PaintingStyle.stroke,
                builder: (Node node) {
                  final nodeId = node.key!.value as String;
                  final nodeData = graphData.nodes.firstWhere((n) => n.id == nodeId, orElse: () => graphData.nodes.first);
                  return _buildNodeWidget(context, nodeData);
                },
              ),
            );
          },
        ),
      ),
    );
  }

  // ノードの見た目を定義するWidget
  Widget _buildNodeWidget(BuildContext context, app_graph.Node nodeData) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _getColorForNodeType(context, nodeData.type),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        nodeData.id,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // ノードの種類に応じて色を返すヘルパーメソッド
  Color _getColorForNodeType(BuildContext context, String type) {
    final colors = Theme.of(context).colorScheme;
    switch (type) {
      case 'topic':
        return colors.primaryContainer;
      case 'emotion':
        return colors.errorContainer;
      case 'issue':
        return colors.secondaryContainer;
      case 'keyword':
        return colors.tertiaryContainer;
      default:
        return Colors.grey[300]!;
    }
  }
  
  // 以下、状態表示用のヘルパーWidget (変更なし)
  Widget _buildLoadingState(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SpinKitFadingCube(
          color: Theme.of(context).primaryColor,
          size: 50.0,
        ),
        const SizedBox(height: 20),
        const Text('AIによる統合分析を実行中...'),
      ],
    );
  }

  Widget _buildErrorState(BuildContext context, Object err, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 60),
          const SizedBox(height: 16),
          Text('おっと、問題が発生しました', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(err.toString().replaceAll("Exception: ", ""), textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => ref.invalidate(graphDataProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('再試行'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.insights, size: 80, color: Theme.of(context).hintColor.withOpacity(0.5)),
          const SizedBox(height: 20),
          Text('分析データがありません', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text('セッションを完了すると、あなたの心の繋がりがここに可視化されます。', textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => ref.invalidate(graphDataProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('更新する'),
          ),
        ],
      ),
    );
  }
}