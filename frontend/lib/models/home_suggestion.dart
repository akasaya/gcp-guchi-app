class HomeSuggestion {
  // ★★★ 修正: 全てのフィールドをnull許容(String?)にする
  final String? title;
  final String? subtitle;
  final String? nodeLabel;
  final String? nodeId;

  HomeSuggestion({
    this.title,
    this.subtitle,
    this.nodeLabel,
    this.nodeId,
  });

  factory HomeSuggestion.fromJson(Map<String, dynamic> json) {
    return HomeSuggestion(
      // ★★★ 修正: `as String` のようなキャストを削除し、nullを許容する
      title: json['title'],
      subtitle: json['subtitle'],
      nodeLabel: json['nodeLabel'],
      nodeId: json['nodeId'],
    );
  }
}