class BookRecommendationResponse {
  final List<BookRecommendation> recommendations;

  BookRecommendationResponse({required this.recommendations});

  factory BookRecommendationResponse.fromJson(Map<String, dynamic> json) {
    var list = json['recommendations'] as List;
    List<BookRecommendation> recommendationsList =
        list.map((i) => BookRecommendation.fromJson(i)).toList();
    return BookRecommendationResponse(recommendations: recommendationsList);
  }
}

class BookRecommendation {
  final String title;
  final String author;
  final String reason;
  final String searchUrl;

  BookRecommendation({
    required this.title,
    required this.author,
    required this.reason,
    required this.searchUrl,
  });

  factory BookRecommendation.fromJson(Map<String, dynamic> json) {
    return BookRecommendation(
      title: json['title'],
      author: json['author'],
      reason: json['reason'],
      searchUrl: json['search_url'],
    );
  }
}