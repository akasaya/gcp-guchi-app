    class HomeSuggestion {
      final String title;
      final String subtitle;
      final String nodeLabel;
      final String nodeId;

      HomeSuggestion({
        required this.title,
        required this.subtitle,
        required this.nodeLabel,
        required this.nodeId,
      });

      factory HomeSuggestion.fromJson(Map<String, dynamic> json) {
        return HomeSuggestion(
          title: json['title'] as String,
          subtitle: json['subtitle'] as String,
          nodeLabel: json['nodeLabel'] as String,
          nodeId: json['nodeId'] as String,
        );
      }
    }