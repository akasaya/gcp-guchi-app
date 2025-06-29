import 'package:flutter/material.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  // オンボーディングの各ページの内容
  final List<Map<String, String>> _onboardingData = [
    {
      "icon": "psychology",
      "title": "あなたの「言葉にならないモヤモヤ」を、AIと共に解き明かす",
      "description":
          "マインドソートは、あなた専属のAIパートナーです。日々の対話を通して、自分でも気づいていない思考のクセや、心の奥にある本当の願いを可視化します。",
    },
    {
      "icon": "swipe",
      "title": "直感的なスワイプで、思考を整理",
      "description":
          "AIからの問いに「はい/いいえ」で答えるだけ。複雑な入力は必要ありません。あなたの直感が、思考を整理する第一歩になります。",
    },
    {
      "icon": "hub",
      "title": "思考の地図で、自分を客観視",
      "description":
          "対話が深まると、あなたの思考パターンがグラフとして可視化されます。点と点が線で結ばれるように、自分の考えの繋がりを発見し、客観的に自分を見つめ直すことができます。",
    },
    {
      "icon": "auto_awesome",
      "title": "さあ、思考の旅へ",
      "description": "準備はできましたか？あなたの心の中を、一緒に探検しましょう。",
    }
  ];

  @override
  Widget build(BuildContext context) {
    // ★ 追加: 画面の幅を取得してPCかどうかを簡易的に判定
    final isDesktop = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      body: SafeArea(
        // ★ 修正: Stackを使ってページとナビゲーションボタンを重ねる
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _onboardingData.length,
                    onPageChanged: (int page) {
                      setState(() {
                        _currentPage = page;
                      });
                    },
                    itemBuilder: (context, index) {
                      return OnboardingPage(
                        icon: _onboardingData[index]['icon']!,
                        title: _onboardingData[index]['title']!,
                        description: _onboardingData[index]['description']!,
                      );
                    },
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    _onboardingData.length,
                    (index) => buildDot(context, index),
                  ),
                ),
                SizedBox(
                  height: 100,
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: _currentPage == _onboardingData.length - 1
                        ? ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size.fromHeight(50),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: _completeOnboarding,
                            child: const Text('はじめる'),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
            // ★ 追加: PCの場合のみナビゲーションボタンを表示
            if (isDesktop)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.center,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // 「前へ」ボタン
                        if (_currentPage > 0)
                          IconButton(
                            icon: const Icon(Icons.arrow_back_ios),
                            onPressed: () {
                              _pageController.previousPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            },
                          )
                        else
                          const SizedBox(width: 48), // ボタンがない場合もスペースを確保
                        // 「次へ」ボタン
                        if (_currentPage < _onboardingData.length - 1)
                          IconButton(
                            icon: const Icon(Icons.arrow_forward_ios),
                            onPressed: () {
                              _pageController.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              );
                            },
                          )
                        else
                          const SizedBox(width: 48), // ボタンがない場合もスペースを確保
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // オンボーディング完了処理
  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);
    if (mounted) {
      Navigator.of(context).pushReplacement(
        // ★ 修正: 遷移先をHomeScreenに変更
      MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
    }
  }

  // ページインジケーターのドット
  Widget buildDot(BuildContext context, int index) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(right: 5),
      height: 6,
      width: _currentPage == index ? 20 : 6,
      decoration: BoxDecoration(
        color: _currentPage == index
            ? Theme.of(context).primaryColor
            : const Color(0xFFD8D8D8),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

// オンボーディングの1ページ分のUI
class OnboardingPage extends StatelessWidget {
  final String icon;
  final String title;
  final String description;

  const OnboardingPage({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    // アイコン名をMaterial Iconsに変換する
    const iconMap = {
      "psychology": Icons.psychology_outlined,
      "swipe": Icons.swipe_outlined,
      "hub": Icons.hub_outlined,
      "auto_awesome": Icons.auto_awesome_outlined
    };

    return Padding(
      padding: const EdgeInsets.all(40.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            iconMap[icon] ?? Icons.help_outline,
            size: 120,
            color: Theme.of(context).primaryColor,
          ),
          const SizedBox(height: 48),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.notoSansJp(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            description,
            textAlign: TextAlign.center,
            style: GoogleFonts.notoSansJp(
              fontSize: 16,
              color: Colors.black54,
            ),
          ),
        ],
      ),
    );
  }
}