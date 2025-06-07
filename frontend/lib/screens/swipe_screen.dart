import 'dart:async'; // Stopwatchのためにインポート
import 'package:flutter/material.dart';
import 'package:swipe_cards/swipe_cards.dart';
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
  final List<SwipeItem> _swipeItems = [];
  late MatchEngine _matchEngine;
  final ApiService _apiService = ApiService();
  bool _isLoading = false;
  double _lastSwipeSpeed = 0.0;
  String? _currentCardQuestionId; 

  Key _swipeCardsKey = UniqueKey();

  // ★★★ ためらい時間計測用のStopwatchを追加 ★★★
  final Stopwatch _hesitationStopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _currentCardQuestionId = widget.initialQuestionId; 
    _addCard(widget.initialQuestionId, widget.initialQuestionText);
    _matchEngine = MatchEngine(swipeItems: _swipeItems);
    // ★★★ 最初のカードが表示されるので、タイマースタート ★★★
    _hesitationStopwatch.start();
  }

  @override
  void dispose() {
    // ★★★ ウィジェット破棄時にタイマーを停止 ★★★
    _hesitationStopwatch.stop();
    super.dispose();
  }

  void _addCard(String questionId, String questionText) {
    final currentQuestionIdForAction = questionId; 
    _swipeItems.add(
      SwipeItem(
        content: QuestionCardContent(questionText: questionText, questionId: questionId),
        likeAction: () {
          // ★★★ タイマー停止 & 時間取得 ★★★
          _hesitationStopwatch.stop();
          final hesitationTime = _hesitationStopwatch.elapsedMilliseconds / 1000.0;
          print("Liked question $currentQuestionIdForAction with speed $_lastSwipeSpeed and hesitation $hesitationTime s");
          _handleSwipeComplete('yes', currentQuestionIdForAction, hesitationTime);
        },
        nopeAction: () {
          // ★★★ タイマー停止 & 時間取得 ★★★
          _hesitationStopwatch.stop();
          final hesitationTime = _hesitationStopwatch.elapsedMilliseconds / 1000.0;
          print("Noped question $currentQuestionIdForAction with speed $_lastSwipeSpeed and hesitation $hesitationTime s");
          _handleSwipeComplete('no', currentQuestionIdForAction, hesitationTime);
        },
      ),
    );
  }

  // 引数に swipedQuestionId を追加
   void _handleSwipeComplete(String direction, String swipedQuestionId, double hesitationTime) {
    double swipeSpeed = _lastSwipeSpeed;
    if (swipeSpeed == 0.0) {
      swipeSpeed = direction == 'yes' ? 100.0 : -100.0;
      print('Swipe speed was 0 or not captured for $swipedQuestionId, using default speed: $swipeSpeed');
    }

    print('Handling swipe: $direction on question $swipedQuestionId with speed $swipeSpeed (abs: ${swipeSpeed.abs()})');
    _fetchNextQuestion(direction, swipeSpeed.abs(), swipedQuestionId, hesitationTime);
    _lastSwipeSpeed = 0.0;
  }

  // ★★★ 引数に hesitationTime を追加 ★★★
  Future<void> _fetchNextQuestion(String direction, double speed, String swipedQuestionId, double hesitationTime) async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await _apiService.recordSwipe(
        sessionId: widget.sessionId,
        questionId: swipedQuestionId,
        answer: direction,
        speed: speed,
        hesitationTime: hesitationTime, // ★★★ hesitationTimeをAPIに渡す ★★★
      );

      if (!mounted) return;


      if (response.containsKey('next_question_id')) {
        final nextQuestionId = response['next_question_id'] as String;
        final nextQuestionText = response['next_question_text'] as String;

        _swipeItems.clear(); 
        _addCard(nextQuestionId, nextQuestionText); 

        setState(() {
          _matchEngine = MatchEngine(swipeItems: _swipeItems); 
          _swipeCardsKey = UniqueKey(); 
          _isLoading = false;
        });
        print("Fetched next question: $nextQuestionId. Swipe items now has 1 item.");

      } else if (response.containsKey('session_status') && response['session_status'] == 'completed') {
       print('Session completed! Navigating to SummaryScreen.');
        if (mounted) {
          // SummaryScreenへ遷移し、現在の画面は置き換える (戻れないようにする)
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => SummaryScreen(sessionId: widget.sessionId),
            ),
          );
        }
      } else {
        print('Unexpected API response: $response');
        // ...(エラーハンドリングは同様)...
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('予期しない応答です: $response')),
          );
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      print('Error fetching next question: $e');
      // ...(エラーハンドリングは同様)...
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('次の質問の取得に失敗: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
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
        child: (_isLoading && _swipeItems.isEmpty) 
            ? const CircularProgressIndicator()
            : _swipeItems.isNotEmpty && _matchEngine.currentItem != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Padding( 
                        padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Row(children: [
                              Icon(Icons.arrow_back, color: Colors.red[700]),
                              const SizedBox(width: 4),
                              Text('いいえ (No)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.red[700])),
                            ]),
                            Row(children: [
                              Text('はい (Yes)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green[700])),
                              const SizedBox(width: 4),
                              Icon(Icons.arrow_forward, color: Colors.green[700]),
                            ]),
                          ],
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onPanEnd: (DragEndDetails details) {
                            _lastSwipeSpeed = details.velocity.pixelsPerSecond.dx;
                            // _currentCardQuestionId は itemChanged で更新されるので、ログではそちらを参照
                            print("Pan End Velocity dx: $_lastSwipeSpeed for displayed card (QID from itemChanged): $_currentCardQuestionId");
                          },
                          child: SwipeCards(
                            key: _swipeCardsKey,
                            matchEngine: _matchEngine,
                            itemBuilder: (BuildContext context, int index) {
                              if (index >= 0 && index < _swipeItems.length) {
                                return _swipeItems[index].content;
                              }
                              return Container(child: const Center(child: Text("カード表示エラー")));
                            },
                            onStackFinished: () {
                              print("Stack finished called (expected after each swipe with current logic).");
                            },
                            itemChanged: (SwipeItem item, int index) {
                              if (item.content is QuestionCardContent) {
                                // setState(() { // _currentCardQuestionId の更新はUIに直接影響しないので setState は不要かも
                                 _currentCardQuestionId = (item.content as QuestionCardContent).questionId;
                                // });
                                print("ItemChanged: Now displaying QID: $_currentCardQuestionId at index $index");
                                // ★★★ 新しいカードが表示されたのでタイマーをリセットして再開 ★★★
                                _hesitationStopwatch.reset();
                                _hesitationStopwatch.start();

                              }
                            },
                            upSwipeAllowed: false,
                            fillSpace: true,
                          ),
                        ),
                      ),
                    ],
                  )
                : (_isLoading
                    ? const CircularProgressIndicator()
                    // 初期表示時や全問回答後などに表示されるテキスト
                    : Center(child: Text( (_currentCardQuestionId == null && widget.initialQuestionText.isNotEmpty) ? '質問を読み込んでいます...' : 'セッションが終了しました。'))),
      ),
    );
  }
}

class QuestionCardContent extends StatelessWidget {
  final String questionText;
  final String questionId;

  const QuestionCardContent({super.key, required this.questionText, required this.questionId});

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
            Text('(QID: $questionId)', style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}