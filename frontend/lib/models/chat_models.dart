class ChatResponse {
  // ★★★ 修正: バックエンドのキー名 'response' に合わせる ★★★
  final String response;
  final List<String> sources;

  // ★★★ 修正: こちらも 'response' に合わせる ★★★
  ChatResponse({required this.response, required this.sources});

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    return ChatResponse(
      // ★★★ 修正: キー名を 'response' に変更し、nullの場合のデフォルト値を用意 ★★★
      response: json['response'] as String? ?? 'AIからの応答がありませんでした。',
      sources: (json['sources'] as List<dynamic>?)?.cast<String>() ?? [],
    );
  }
}

// ノードタップ時の応答を格納するクラス
class NodeTapResponse {
  final String initialSummary;
  final String nodeLabel;
  final List<ChatAction> actions;
  final String? nodeId;

  NodeTapResponse({
    required this.initialSummary,
    required this.nodeLabel,
    required this.actions,
    this.nodeId,
  });

  factory NodeTapResponse.fromJson(Map<String, dynamic> json) {
    var actionsFromJson = json['actions'] as List<dynamic>?;
    List<ChatAction> actionsList = actionsFromJson != null
        ? actionsFromJson.map((i) => ChatAction.fromJson(i)).toList()
        : [];

    return NodeTapResponse(
      // ★★★ 修正: キー名を 'initialSummary' に変更し、nullの場合のデフォルト値を用意 ★★★
      initialSummary: json['initialSummary'] as String? ?? '',
      // ★★★ 修正: キー名を 'nodeLabel' に変更し、nullの場合のデフォルト値を用意 ★★★
      nodeLabel: json['nodeLabel'] as String? ?? '',
      actions: actionsList,
      // ★★★ 修正: キー名を 'nodeId' に変更 ★★★
      nodeId: json['nodeId'] as String?,
    );
  }
}

// チャット内のアクションボタンを表現するクラス
class ChatAction {
  final String id;
  final String title; // ★★★ 修正: バックエンドのキー名 'title' に合わせる ★★★
  final String? content;
  final List<String>? sources;


  ChatAction({
    required this.id,
    required this.title, // ★★★ 修正: こちらも 'title' に合わせる ★★★
    this.content,
    this.sources,
  });

  factory ChatAction.fromJson(Map<String, dynamic> json) {
    return ChatAction(
      // ★★★ 修正: バックエンドのキー名は 'type' なので、id にはそれを使う。nullにも対応。 ★★★
      id: json['type'] as String? ?? 'unknown',
      // ★★★ 修正: バックエンドのキー名 'title' に合わせる。nullにも対応。 ★★★
      title: json['title'] as String? ?? '無題のアクション',
      // ★★★ 修正: content と sources を追加し、nullに対応 ★★★
      content: json['content'] as String?,
      sources: json['sources'] != null ? List<String>.from(json['sources']) : null,
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
      // ★★★ 修正: キー名を 'nodeId' に変更し、nullの場合のデフォルト値を用意 ★★★
      nodeId: json['nodeId'] as String? ?? '',
      // ★★★ 修正: キー名を 'nodeLabel' に変更し、nullの場合のデフォルト値を用意 ★★★
      nodeLabel: json['nodeLabel'] as String? ?? '',
    );
  }
}