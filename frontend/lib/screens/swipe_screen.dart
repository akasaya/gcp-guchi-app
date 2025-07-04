import 'package:flutter/material.dart';
import 'package:frontend/screens/summary_screen.dart';
import 'package:frontend/services/api_service.dart';
import 'package:swipe_cards/swipe_cards.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // ★ Firestoreをインポート

class SwipeScreen extends StatefulWidget {
  final String sessionId;
  final List<Map<String, dynamic>> questions;
  final int turn;
  final ApiService? apiService;
  final FirebaseFirestore? firestore; // ★ HomeScreenからfirestoreを受け取る口を追加

  const SwipeScreen({
    super.key,
    required this.sessionId,
    required this.questions,
    this.turn = 1,
    this.apiService,
    this.firestore, // ★ コンストラクタに追加
  });

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends State<SwipeScreen> {
  // final ApiService _apiService = ApiService(); // ← この行を削除
  late final ApiService _apiService;           // ← この行に変更
  late final MatchEngine _matchEngine;
  final List<SwipeItem> _swipeItems = [];

  late DateTime _questionStartTime;
  int _currentQuestionIndex = 0; // ★ 状態変数を追加

  @override
  void initState() {
    super.initState();
    _apiService = widget.apiService ?? ApiService(); // ★ この行を追加して、渡されたApiServiceを使う
    for (var i = 0; i < widget.questions.length; i++) {
      final questionData = widget.questions[i];
      _swipeItems.add(
        SwipeItem(
          content: questionData,
          // --- ↓↓↓ ここから修正 (1箇所目) ↓↓↓ ---
          likeAction: () => _onSwipe(true, questionData, i),  // bool値の true を渡す
          nopeAction: () => _onSwipe(false, questionData, i), // bool値の false を渡す
          // --- ↑↑↑ ここまで修正 (1箇所目) ↑↑↑ ---
        ),
      );
    }
    _matchEngine = MatchEngine(swipeItems: _swipeItems);
    _questionStartTime = DateTime.now();
  }

   void _onSwipe(bool isYes, Map<String, dynamic> questionData, int index) {
    final hesitationTime =
        DateTime.now().difference(_questionStartTime).inMilliseconds / 1000.0;

    _apiService.recordSwipe(
      sessionId: widget.sessionId,
      questionId: questionData['question_id'],
      answer: isYes,
      hesitationTime: hesitationTime,
      swipeSpeed: 0,
      turn: index + 1,
    );

    // ★★★ 修正点 ★★★
    // onStackFinishedが信頼できない問題への対策として、手動で最後のカードか判定する。
    if (index >= _swipeItems.length - 1) {
      // Future.delayed を削除し、即座にAPI呼び出しと画面遷移を実行する。
      // これにより、テストと実装双方の複雑性を解消する。
      _apiService.postSummary(sessionId: widget.sessionId);
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => SummaryScreen(
            sessionId: widget.sessionId,
            apiService: _apiService,
            firestore: widget.firestore,
          ),
        ),
      );
    }
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
            child: Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final screenWidth = constraints.maxWidth;
                  // 画面幅に応じてカードのサイズやパディングを調整
                  final cardWidth = screenWidth > 600 ? screenWidth * 0.5 : screenWidth * 0.9;
                  // ★★★ 修正点 ★★★
                  // 高さを幅に連動させることで、アスペクト比を固定します。
                  final cardHeight = cardWidth * (4 / 3); // 縦横比 3:4
                  final padding = screenWidth > 600 ? 24.0 : 16.0;
                  final textStyle = screenWidth > 600
                      ? Theme.of(context).textTheme.headlineSmall
                      : Theme.of(context).textTheme.titleLarge;

                  return SizedBox(
                    height: cardHeight,
                    width: cardWidth,
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
                              padding: EdgeInsets.all(padding),
                              child: Text(
                                question,
                                textAlign: TextAlign.center,
                                style: textStyle,
                              ),
                            ),
                          ),
                        );
                      },
                      onStackFinished: () {
                        // ★★★ 修正: 要約APIを呼び出し、結果を待たずにサマリー画面に遷移 ★★★
                        _apiService.postSummary(sessionId: widget.sessionId);
                        
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (context) => SummaryScreen(
                              sessionId: widget.sessionId,
                              apiService: _apiService, // ★ 以前の修正
                              firestore: widget.firestore, // ★ ここでfirestoreをSummaryScreenに渡す
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
                  );
                },
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