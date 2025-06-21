class AnalysisSummary {
  final int totalSessions;
  final List<TopicCount> topTopics;
  final String? mostFrequentTopic;

  AnalysisSummary({
    required this.totalSessions,
    required this.topTopics,
    this.mostFrequentTopic,
  });

  factory AnalysisSummary.fromJson(Map<String, dynamic> json) {
    var topicsList = json['top_topics'] as List;
    List<TopicCount> topics = topicsList.map((i) => TopicCount.fromJson(i)).toList();

    return AnalysisSummary(
      totalSessions: json['total_sessions'],
      topTopics: topics,
      mostFrequentTopic: json['most_frequent_topic'],
    );
  }
}

class TopicCount {
  final String topic;
  final int count;

  TopicCount({required this.topic, required this.count});

  factory TopicCount.fromJson(Map<String, dynamic> json) {
    return TopicCount(
      topic: json['topic'],
      count: json['count'],
    );
  }
}