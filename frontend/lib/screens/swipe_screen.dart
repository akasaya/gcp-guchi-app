import 'package:flutter/material.dart';
import 'package:frontend/screens/summary_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:swipe_cards/swipe_cards.dart';

class SwipeScreen extends StatefulWidget {
  final String sessionId;
  final List<Map<String, dynamic>> questions;
  final int turn; // 追加

  const SwipeScreen({
    super.key,
    required this.sessionId,
    required this.questions,
    this.turn = 1, // 追加
  });

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends State<SwipeScreen> {
  final ApiService _apiService = ApiService();
  late final MatchEngine _matchEngine;
  final List<SwipeItem> _swipeItems = [];
  final List<Map<String, dynamic>> _swipesDataForSummary = [];

  late DateTime _questionStartTime;
  int _currentQuestionIndex = 0; // ★ 状態変数を追加

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.questions.length; i++) {
      final questionData = widget.questions[i];
      _swipeItems.add(
        SwipeItem(
          content: questionData,
          likeAction: () => _onSwipe('yes', questionData, i),
          nopeAction: () => _onSwipe('no', questionData, i),
          // onSlideUpdate: (SlideRegion? region) async {}
        ),
      );
    }
    _matchEngine = MatchEngine(swipeItems: _swipeItems);
    _questionStartTime = DateTime.now();
  }

  void _onSwipe(String answer, Map<String, dynamic> questionData, int index) {
    final hesitationTime =
        DateTime.now().difference(_questionStartTime).inMilliseconds / 1000.0;

    // /summaryエンドポイントに送信するデータにはbool値を入れる
    _swipesDataForSummary.add({
      'question_text': questionData['question_text'],
      'answer': answer == 'yes', // 'yes'の場合true、'no'の場合false
      'hesitation_time': hesitationTime,
    });

    // /swipeエンドポイントには互換性のためstringのまま送信
    _apiService.recordSwipe(
      sessionId: widget.sessionId,
      questionId: questionData['question_id'],
      answer: answer,
      hesitationTime: hesitationTime,
      swipeSpeed: 0, // speedは現在取得できないため0
      turn: widget.turn, // 追加
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            '質問 ${_currentQuestionIndex + 1} / ${_swipeItems.length}'),
        automaticallyImplyLeading: false,
      ),
       body: Column(
        children: [
          Expanded(
            // ★★★ この child: が重要です ★★★
            child: Center(
              child: SizedBox(
                height: MediaQuery.of(context).size.height * 0.8,
                width: MediaQuery.of(context).size.width * 0.5,
                child: SwipeCards(
                  matchEngine: _matchEngine,
                  itemBuilder: (BuildContext context, int index) {
                    final question =
                        _swipeItems[index].content['question_text'] as String;
                    return Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24.0),
                          child: Text(
                            question,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                      ),
                    );
                  },
                  onStackFinished: () {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (context) => SummaryScreen(
                          sessionId: widget.sessionId,
                          swipes: _swipesDataForSummary,
                        ),
                      ),
                    );
                  },
                  itemChanged: (SwipeItem item, int index) {
                    setState(() {
                      _currentQuestionIndex = index;
                    });
                    // 新しいカードが表示されたタイミングでタイマーをリセット
                    _questionStartTime = DateTime.now();
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 40.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                ElevatedButton(
                  onPressed: () {
                    _matchEngine.currentItem?.nope();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade400,
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(24),
                  ),
                  child:
                      const Icon(Icons.close, color: Colors.white, size: 40),
                ),
                ElevatedButton(
                  onPressed: () {
                    _matchEngine.currentItem?.like();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade400,
                    shape: const CircleBorder(),
                    padding: const EdgeInsets.all(24),
                  ),
                  child:
                      const Icon(Icons.check, color: Colors.white, size: 40),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}