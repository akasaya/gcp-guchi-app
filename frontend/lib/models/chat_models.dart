class ChatResponse {
  final String response;
  final List<String> sources;
  final String? requestId; // ★★★ request_id を追加 ★★★

  ChatResponse({
    required this.response, 
    required this.sources,
    this.requestId, // ★★★ request_id をコンストラクタに追加 ★★★
  });

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    return ChatResponse(
      response: json['response'] as String? ?? 'AIからの応答がありませんでした。',
      sources: (json['sources'] as List<dynamic>?)?.cast<String>() ?? [],
      requestId: json['request_id'] as String?, // ★★★ JSONからrequest_idを読み込む ★★★
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

class TopicCount {
  final String topic;
  final int count;

  TopicCount({required this.topic, required this.count});

  factory TopicCount.fromJson(Map<String, dynamic> json) {
    return TopicCount(
      topic: json['topic'] as String? ?? '不明なトピック',
      count: json['count'] as int? ?? 0,
    );
  }
}

class AnalysisSummary {
  final int totalSessions;
  final List<TopicCount> topicCounts;

  AnalysisSummary({
    required this.totalSessions,
    required this.topicCounts,
  });

  factory AnalysisSummary.fromJson(Map<String, dynamic> json) {
    final countsFromJson = json['topic_counts'] as List<dynamic>?;
    final List<TopicCount> topicCountsList = countsFromJson
            ?.map((i) => TopicCount.fromJson(i as Map<String, dynamic>))
            .toList() ??
        [];

    return AnalysisSummary(
      totalSessions: json['total_sessions'] as int? ?? 0,
      topicCounts: topicCountsList,
    );
  }
}

// チャット内のアクションボタンを表現するクラス
class ChatAction {
  final String id;
  final String title;
  final String? content;
  final List<String>? sources;


  ChatAction({
    required this.id,
    required this.title,
    this.content,
    this.sources,
  });

  factory ChatAction.fromJson(Map<String, dynamic> json) {
    return ChatAction(
      // ★★★★★ 修正箇所 ★★★★★
      // 'type' ではなく、バックエンドが返す正しいキー 'id' を読み込む
      id: json['id'] as String? ?? 'unknown',
      title: json['title'] as String? ?? '無題のアクション',
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