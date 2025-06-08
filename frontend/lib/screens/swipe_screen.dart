import 'dart:async';
import 'package:flutter/material.dart';
import 'package:swipe_cards/swipe_cards.dart';
import '../services/api_service.dart';
import './summary_screen.dart';

class SwipeScreen extends StatefulWidget {
  final String sessionId;
  final List<Map<String, dynamic>> questions;

  const SwipeScreen({
    super.key,
    required this.sessionId,
    required this.questions,
  });

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class QuestionCardContent extends StatelessWidget {
  final String questionText;

  const QuestionCardContent({super.key, required this.questionText});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            offset: const Offset(0, 17),
            blurRadius: 23,
            spreadRadius: -13,
            color: Colors.black.withOpacity(0.2),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Text(
          questionText,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, color: Colors.black87),
        ),
      ),
    );
  }
}

class _SwipeScreenState extends State<SwipeScreen> {
  final ApiService _apiService = ApiService();
  late final MatchEngine _matchEngine;
  final List<SwipeItem> _swipeItems = [];

  final Stopwatch _hesitationTimer = Stopwatch();
  final Stopwatch _swipeTimer = Stopwatch();

  @override
  void initState() {
    super.initState();
    
    for (var questionData in widget.questions) {
      final questionId = questionData['question_id'] as String;
      final questionText = questionData['question_text'] as String;

      _swipeItems.add(SwipeItem(
        content: QuestionCardContent(questionText: questionText),
        likeAction: () => _handleSwipe('yes', questionId),
        nopeAction: () => _handleSwipe('no', questionId),
        onSlideUpdate: (region) async {
          if (!_swipeTimer.isRunning) {
            _swipeTimer.start();
          }
        },
      ));
    }

    _matchEngine = MatchEngine(swipeItems: _swipeItems);
    _hesitationTimer.start();
  }

  @override
  void dispose() {
    _hesitationTimer.stop();
    _swipeTimer.stop();
    super.dispose();
  }

  void _handleSwipe(String direction, String swipedQuestionId) {
    _hesitationTimer.stop();
    if (_swipeTimer.isRunning) {
      _swipeTimer.stop();
    }
    
    final hesitationTime = _hesitationTimer.elapsedMilliseconds;
    final swipeDuration = _swipeTimer.elapsedMilliseconds;

    _apiService.recordSwipe(
      sessionId: widget.sessionId,
      questionId: swipedQuestionId,
      answer: direction,
      hesitationTime: hesitationTime / 1000.0,
      speed: swipeDuration.toDouble(),
    ).catchError((e) {
      print("Failed to record swipe for QID $swipedQuestionId: $e");
    });

    _hesitationTimer.reset();
    _swipeTimer.reset();
    _hesitationTimer.start();
  }
  
  void _onStackFinished() {
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => SummaryScreen(sessionId: widget.sessionId),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('質問にスワイプで回答'),
      ),
      body: _swipeItems.isEmpty
          ? const Center(child: Text("質問がありません。"))
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.arrow_back, color: Colors.red.withOpacity(0.7)),
                          const SizedBox(width: 8),
                          Text(
                            'いいえ (No)',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.red.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Text(
                            'はい (Yes)',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.green.withOpacity(0.7),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.arrow_forward, color: Colors.green.withOpacity(0.7)),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: SwipeCards(
                      matchEngine: _matchEngine,
                      itemBuilder: (BuildContext context, int index) {
                        return _swipeItems[index].content;
                      },
                      onStackFinished: _onStackFinished,
                      upSwipeAllowed: false,
                      fillSpace: true,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}