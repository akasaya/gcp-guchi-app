import 'package:flutter/foundation.dart';

/// APIからのデータを安全に整数に変換するヘルパー関数
int _parseInt(dynamic source, int defaultValue) {
  if (source == null) return defaultValue;
  if (source is int) return source;
  if (source is double) return source.toInt();
  return int.tryParse(source.toString()) ?? defaultValue;
}

@immutable
class GraphData {
  final List<Node> nodes;
  final List<Edge> edges;

  const GraphData({
    required this.nodes,
    required this.edges,
  });

  factory GraphData.fromJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'] as List<dynamic>? ?? [];
    final rawEdges = json['edges'] as List<dynamic>? ?? [];

    final nodes = rawNodes
        .map((nodeJson) => Node.fromJson(nodeJson as Map<String, dynamic>))
        .toList();

    // 存在しないノードを指すエッジを除去するための参照整合性チェック
    final nodeIds = nodes.map((n) => n.id).toSet();
    final edges = rawEdges
        .map((edgeJson) => Edge.fromJson(edgeJson as Map<String, dynamic>))
        .where((edge) => nodeIds.contains(edge.source) && nodeIds.contains(edge.target))
        .toList();

    return GraphData(nodes: nodes, edges: edges);
  }
}

@immutable
class Node {
  final String id;
  final String type;
  final int size;

  const Node({
    required this.id,
    required this.type,
    required this.size,
  });

  factory Node.fromJson(Map<String, dynamic> json) {
    return Node(
      id: json['id'] as String? ?? 'unknown_id',
      type: json['type'] as String? ?? 'keyword',
      // AIがどんな形式でsizeを返しても、安全に整数に変換します
      size: _parseInt(json['size'], 15),
    );
  }
}

@immutable
class Edge {
  final String source;
  final String target;
  final int weight;

  const Edge({
    required this.source,
    required this.target,
    required this.weight,
  });

  factory Edge.fromJson(Map<String, dynamic> json) {
    return Edge(
      source: json['source'] as String? ?? '',
      target: json['target'] as String? ?? '',
      // AIがどんな形式でweightを返しても、安全に整数に変換します
      weight: _parseInt(json['weight'], 1),
    );
  }
}