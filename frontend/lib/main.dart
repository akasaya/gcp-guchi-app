import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/screens/onboarding_screen.dart';
import 'package:frontend/screens/login_screen.dart'; // ★ LoginScreenをインポート
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/foundation.dart';

final sharedPreferencesProvider =
    FutureProvider<SharedPreferences>((ref) async {
  return await SharedPreferences.getInstance();
});

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  if (kIsWeb) {
    await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
  }

  // RECAPTCHA_SITE_KEYは--dart-defineで渡す想定
  const siteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY');

  await FirebaseAppCheck.instance.activate(
    webProvider: ReCaptchaV3Provider(siteKey),
  );

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;

    return MaterialApp(
      title: 'マインドソート',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
        textTheme: GoogleFonts.notoSansJpTextTheme(textTheme).apply(
          bodyColor: Colors.black87,
          displayColor: Colors.black87,
        ),
      ),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends ConsumerWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // ★ authStateChangesProviderを監視して、認証状態(Userオブジェクト)を取得
    final authState = ref.watch(authStateChangesProvider);
    final onboardingPrefs = ref.watch(sharedPreferencesProvider);

    // ★ AsyncValue.when を使って、認証状態に応じた画面表示を制御
    return authState.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (err, stack) => Scaffold(
        body: Center(child: Text('エラーが発生しました: $err')),
      ),
      data: (user) {
        // 認証状態が取得できたら、オンボーディング状態をチェック
        return onboardingPrefs.when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (err, stack) =>
              const Scaffold(body: Center(child: Text('設定の読み込みに失敗しました'))),
          data: (prefs) {
            final onboardingCompleted =
                prefs.getBool('onboarding_completed') ?? false;

            if (!onboardingCompleted) {
              // オンボーディングがまだなら、認証状態にかかわらずオンボーディング画面へ
              return const OnboardingScreen();
            }

            // オンボーディング完了済みの場合
            if (user != null) {
              // ユーザーがログインしていればホーム画面へ
              return const HomeScreen();
            } else {
              // ユーザーがログアウトしていればログイン画面へ
              return const LoginScreen(
                googleWebClientId: String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
              );
            }
          },
        );
      },
    );
  }
}