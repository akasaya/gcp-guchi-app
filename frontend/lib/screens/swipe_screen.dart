import 'dart:async';
import 'package:flutter/material.dart';
import 'package:swipe_cards/swipe_cards.dart';
import 'package:swipe_cards/draggable_card.dart';
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
  final List<SwipeItem> _swipeItems = [];
  late Key _swipeCardsKey;

  String? _currentCardQuestionId;
  bool _isLoading = false;

  final Stopwatch _hesitationTimer = Stopwatch();
  final Stopwatch _swipeTimer = Stopwatch();
  
  // セッションの会話履歴を保持するリスト
  final List<Map<String, String>> _sessionHistory = [];

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
        // ★★★ エラー修正: async を再度追加します。これによりFutureを返すという要件を満たします。 ★★★
        onSlideUpdate: (SlideRegion? region) async {
          if (!_swipeTimer.isRunning) {
            _swipeTimer.start();
          }
        },
        likeAction: () {
          _handleSwipe('yes', questionId, questionText);
        },
        nopeAction: () {
          _handleSwipe('no', questionId, questionText);
        },
      ),
    );
  }

  void _handleSwipe(String direction, String swipedQuestionId, String swipedQuestionText) {
    _hesitationTimer.stop();
    if (_swipeTimer.isRunning) {
      _swipeTimer.stop();
    }
    final hesitationTime = _hesitationTimer.elapsedMilliseconds;
    final swipeDuration = _swipeTimer.elapsedMilliseconds;

    print(
        "Swiped $direction on QID: $swipedQuestionId. Hesitation: $hesitationTime ms, Swipe Duration: $swipeDuration ms");

    // セッション履歴を更新
    _sessionHistory.add({
      'question': swipedQuestionText,
      'answer': direction,
    });

    _fetchNextQuestion(direction, swipedQuestionId, hesitationTime, swipeDuration);

    _hesitationTimer.reset();
    _swipeTimer.reset();
  }

  // ★★★ 修正点2: セッション完了時のエラーを修正し、画面遷移を確実にする ★★★
  Future<void> _fetchNextQuestion(String direction, String swipedQuestionId, int hesitationTime, int swipeDuration) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _swipeItems.clear(); // 次の質問をロードする間、カードを非表示にする
    });

    try {
      // Step 1: スワイプを記録する
      await _apiService.recordSwipe(
        sessionId: widget.sessionId,
        questionId: swipedQuestionId,
        answer: direction,
        hesitationTime: hesitationTime / 1000.0,
        speed: swipeDuration.toDouble(),
      );

      if (!mounted) return;

      // Step 2: 会話履歴を文字列に変換
      String historyString = _sessionHistory.map((qa) => "Q: ${qa['question']}\nA: ${qa['answer']}").join('\n\n');

      // Step 3: 新しい質問を生成する (こちらが完了を返す可能性がある)
      final questionResponse = await _apiService.generateQuestion(
        sessionId: widget.sessionId,
        history: historyString,
      );

      if (!mounted) return;
      
      // Step 4: レスポンスを判定し、画面遷移またはUI更新を行う
      // Case A: セッションが完了した場合
      if (questionResponse.containsKey('session_status') &&
          questionResponse['session_status'] == 'completed') {
        print('Session completed! Navigating to SummaryScreen.');
        _hesitationTimer.stop();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => SummaryScreen(sessionId: widget.sessionId),
          ),
        );
        return; // ★★★ 処理をここで終了させる
      }

      // Case B: 次の質問が返ってきた場合
      if (questionResponse.containsKey('next_question_id')) {
        final nextQuestionId = questionResponse['next_question_id'] as String;
        final nextQuestionText = questionResponse['next_question_text'] as String;
        
        _currentCardQuestionId = nextQuestionId;
        _addCard(nextQuestionId, nextQuestionText);

        setState(() {
          _matchEngine = MatchEngine(swipeItems: _swipeItems);
          _swipeCardsKey = UniqueKey();
          _isLoading = false;
        });
        
        _hesitationTimer.start();
        print("Fetched next question: $nextQuestionId.");
      } 
      // Case C: 想定外の応答が来た場合
      else {
        throw Exception('Unexpected API response: $questionResponse');
      }
    } catch (e) {
      print('Error during swipe/question generation: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラーが発生しました: $e')),
        );
        Navigator.of(context).pop();
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
        child: _isLoading
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
                            return _swipeItems[index].content;
                          },
                          onStackFinished: () {
                            print("Stack finished.");
                            setState(() {
                               _isLoading = false;
                            });
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
                : const Center(
                    child: Text('セッションが終了しました。')
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