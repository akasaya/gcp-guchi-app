class ChatResponse {
  final String answer;
  final List<String> sources;

  ChatResponse({required this.answer, required this.sources});

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    return ChatResponse(
      answer: json['answer'] as String,
      sources: (json['sources'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

// ノードタップ時の応答を格納するクラス
class NodeTapResponse {
  final String initialSummary;
  final String nodeLabel;
  final List<ChatAction> actions;

  NodeTapResponse({
    required this.initialSummary,
    required this.nodeLabel,
    required this.actions,
  });

  factory NodeTapResponse.fromJson(Map<String, dynamic> json) {
    var actionsFromJson = json['actions'] as List<dynamic>?;
    List<ChatAction> actionsList = actionsFromJson != null
        ? actionsFromJson.map((i) => ChatAction.fromJson(i)).toList()
        : [];

    return NodeTapResponse(
      initialSummary: json['initial_summary'] as String,
      nodeLabel: json['node_label'] as String,
      actions: actionsList,
    );
  }
}

// チャット内のアクションボタンを表現するクラス
class ChatAction {
  final String id;
  final String label;

  ChatAction({required this.id, required this.label});

  factory ChatAction.fromJson(Map<String, dynamic> json) {
    return ChatAction(
      id: json['id'] as String,
      label: json['label'] as String,
    );
  }
}