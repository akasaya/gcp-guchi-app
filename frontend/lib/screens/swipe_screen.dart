import 'dart:async';
import 'package:flutter/material.dart';
import 'package:swipe_cards/swipe_cards.dart';
import 'package:swipe_cards/draggable_card.dart'; // SlideRegionを解決するために追加
import '../services/api_service.dart';
import './summary_screen.dart';

class SwipeScreen extends StatefulWidget {
  final String sessionId;
  final String initialQuestionId;
  final String initialQuestionText;

  const SwipeScreen({
    super.key,
    required this.sessionId,
    required this.initialQuestionId,
    required this.initialQuestionText,
  });

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends State<SwipeScreen> {
  final ApiService _apiService = ApiService();
  late MatchEngine _matchEngine;
  List<SwipeItem> _swipeItems = [];
  late Key _swipeCardsKey;

  String? _currentCardQuestionId;
  bool _isLoading = false;

  final Stopwatch _hesitationTimer = Stopwatch();
  final Stopwatch _swipeTimer = Stopwatch();

  @override
  void initState() {
    super.initState();
    _swipeCardsKey = UniqueKey();
    _currentCardQuestionId = widget.initialQuestionId;

    _addCard(widget.initialQuestionId, widget.initialQuestionText);
    _matchEngine = MatchEngine(swipeItems: _swipeItems);

    _hesitationTimer.start();
  }

  @override
  void dispose() {
    _hesitationTimer.stop();
    _swipeTimer.stop();
    super.dispose();
  }

  void _addCard(String questionId, String questionText) {
    _swipeItems.add(
      SwipeItem(
        content: QuestionCardContent(
            questionText: questionText, questionId: questionId),
        onSlideUpdate: (SlideRegion? region) async { // ★★★★★ asyncキーワードを追加 ★★★★★
          if (!_swipeTimer.isRunning) {
            _swipeTimer.start();
          }
        },
        likeAction: () {
          _handleSwipe('yes', questionId);
        },
        nopeAction: () {
          _handleSwipe('no', questionId);
        },
      ),
    );
  }

  void _handleSwipe(String direction, String swipedQuestionId) {
    _hesitationTimer.stop();
    // スワイプタイマーが万が一動いていなくてもエラーにならないように停止
    if (_swipeTimer.isRunning) {
      _swipeTimer.stop();
    }
    final hesitationTime = _hesitationTimer.elapsedMilliseconds;
    final swipeDuration = _swipeTimer.elapsedMilliseconds;

    print(
        "Swiped $direction on QID: $swipedQuestionId. Hesitation: $hesitationTime ms, Swipe Duration: $swipeDuration ms");

    _fetchNextQuestion(direction, swipedQuestionId, hesitationTime, swipeDuration);

    _hesitationTimer.reset();
    _swipeTimer.reset();
  }

  Future<void> _fetchNextQuestion(String direction, String swipedQuestionId, int hesitationTime, int swipeDuration) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await _apiService.recordSwipe(
        sessionId: widget.sessionId,
        questionId: swipedQuestionId,
        answer: direction,
        hesitationTime: hesitationTime / 1000.0, // APIは秒単位を想定
        speed: swipeDuration.toDouble(), // バックエンドの 'speed' にスワイプ時間(ms)を渡す
      );

      if (!mounted) return;

      if (response.containsKey('session_status') &&
          response['session_status'] == 'completed') {
        print('Session completed! Navigating to SummaryScreen.');
        if (mounted) {
          _hesitationTimer.stop();
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => SummaryScreen(sessionId: widget.sessionId),
            ),
          );
        }
        return;
      }

      if (response.containsKey('next_question_id') &&
          response['next_question_id'] != null) {
        final nextQuestionId = response['next_question_id'] as String;
        final nextQuestionText = response['next_question_text'] as String;
        
        _currentCardQuestionId = nextQuestionId;

        _swipeItems.clear();
        _addCard(nextQuestionId, nextQuestionText);

        setState(() {
          _matchEngine = MatchEngine(swipeItems: _swipeItems);
          _swipeCardsKey = UniqueKey();
          _isLoading = false;
        });
        
        _hesitationTimer.start();

        print(
            "Fetched next question: $nextQuestionId. Swipe items now has 1 item.");
      } else {
        print('Unexpected API response: $response');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('予期しない応答です: $response')),
          );
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      print('Error fetching next question: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('次の質問の取得に失敗: $e')),
        );
        setState(() { _isLoading = false; });
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('質問にスワイプで回答'),
      ),
      body: Center(
        child: _isLoading && _swipeItems.isEmpty
            ? const CircularProgressIndicator()
            : _swipeItems.isNotEmpty && _matchEngine.currentItem != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20.0, vertical: 10.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Row(children: [
                              Icon(Icons.arrow_back, color: Colors.red[700]),
                              const SizedBox(width: 4),
                              Text('いいえ (No)',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red[700])),
                            ]),
                            Row(children: [
                              Text('はい (Yes)',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green[700])),
                              const SizedBox(width: 4),
                              Icon(Icons.arrow_forward,
                                  color: Colors.green[700]),
                            ]),
                          ],
                        ),
                      ),
                      Expanded(
                        child: SwipeCards(
                          key: _swipeCardsKey,
                          matchEngine: _matchEngine,
                          itemBuilder: (BuildContext context, int index) {
                            if (index >= 0 && index < _swipeItems.length) {
                              return _swipeItems[index].content;
                            }
                            return Container(
                                child: const Center(
                                    child: Text("カード表示エラー")));
                          },
                          onStackFinished: () {
                            print("Stack finished.");
                          },
                          itemChanged: (SwipeItem item, int index) {
                            if (item.content is QuestionCardContent) {
                              final qid = (item.content as QuestionCardContent).questionId;
                              print("ItemChanged: Now displaying QID: $qid at index $index");
                            }
                          },
                          upSwipeAllowed: false,
                          fillSpace: true,
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: _isLoading 
                      ? const CircularProgressIndicator()
                      : const Text('セッションが終了しました。')
                ),
      ),
    );
  }
}

class QuestionCardContent extends StatelessWidget {
  final String questionText;
  final String questionId;

  const QuestionCardContent(
      {super.key, required this.questionText, required this.questionId});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Container(
        padding: const EdgeInsets.all(20.0),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              questionText,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text('(QID: $questionId)',
                style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}