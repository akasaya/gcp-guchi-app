import 'package:flutter/material.dart';

/// APIからのデータを安全に数値に変換するヘルパー関数
double _parseDouble(dynamic source, double defaultValue) {
  if (source == null) return defaultValue;
  if (source is double) return source;
  if (source is int) return source.toDouble();
  return double.tryParse(source.toString()) ?? defaultValue;
}

Color _colorFromHex(String hexColor) {
  final hexCode = hexColor.replaceAll('#', '');
  if (hexCode.length == 6) {
    return Color(int.parse('FF$hexCode', radix: 16));
  }
  return Colors.grey; // デフォルト色
}

@immutable
class GraphData {
  final List<NodeData> nodes;
  final List<EdgeData> edges;

  const GraphData({
    required this.nodes,
    required this.edges,
  });

  factory GraphData.fromJson(Map<String, dynamic> json) {
    final rawNodes = json['nodes'] as List<dynamic>? ?? [];
    final rawEdges = json['edges'] as List<dynamic>? ?? [];

    final nodes = rawNodes
        .map((nodeJson) => NodeData.fromJson(nodeJson as Map<String, dynamic>))
        .toList();

    final nodeIds = nodes.map((n) => n.id).toSet();
    final edges = rawEdges
        .map((edgeJson) => EdgeData.fromJson(edgeJson as Map<String, dynamic>))
        .where((edge) => nodeIds.contains(edge.source) && nodeIds.contains(edge.target))
        .toList();

    return GraphData(nodes: nodes, edges: edges);
  }
}

@immutable
class NodeData {
  final String id;
  final String label;
  final String type;
  final int turn;
  final double size;
  final Color color;

  const NodeData({
    required this.id,
    required this.label,
    required this.type,
    required this.turn,
    required this.size,
    required this.color,
  });

  factory NodeData.fromJson(Map<String, dynamic> json) {
    return NodeData(
      id: json['id'] as String? ?? 'unknown_id',
      label: json['label'] as String? ?? json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'keyword',
      turn: json['turn'] as int? ?? 0,
      size: _parseDouble(json['size'], 15.0),
      color: _colorFromHex(json['color'] as String? ?? '#CCCCCC'),
    );
  }
}

@immutable
class EdgeData {
  final String source;
  final String target;
  final double weight;
  final String label;

  const EdgeData({
    required this.source,
    required this.target,
    required this.weight,
    required this.label,
  });

  factory EdgeData.fromJson(Map<String, dynamic> json) {
    return EdgeData(
      source: json['source'] as String? ?? '',
      target: json['target'] as String? ?? '',
      weight: _parseDouble(json['weight'], 1.0),
      label: json['label'] as String? ?? '',
    );
  }
}