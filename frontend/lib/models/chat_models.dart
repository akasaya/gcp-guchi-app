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
  final String? nodeId; // ★★★ 変更点: ホーム画面からの遷移で使用するため追加

  NodeTapResponse({
    required this.initialSummary,
    required this.nodeLabel,
    required this.actions,
    this.nodeId, // ★★★ 変更点: コンストラクタに追加
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

class HomeSuggestion {
  final String title;
  final String subtitle;
  final String nodeId;
  final String nodeLabel;

  HomeSuggestion({
    required this.title,
    required this.subtitle,
    required this.nodeId,
    required this.nodeLabel,
  });

  factory HomeSuggestion.fromJson(Map<String, dynamic> json) {
    return HomeSuggestion(
      title: json['title'] as String? ?? 'AIからの提案',
      subtitle: json['subtitle'] as String? ?? '気になることについて思考を整理しませんか？',
      nodeId: json['node_id'] as String,
      nodeLabel: json['node_label'] as String,
    );
  }
}
