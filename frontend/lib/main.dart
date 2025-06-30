import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:frontend/providers/auth_provider.dart'; // ★ 修正
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/screens/onboarding_screen.dart';
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
    // ★ 修正: ここでの永続化設定は重要なので残します。
    await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
  }

  const siteKey = String.fromEnvironment('RECAPTCHA_SITE_KEY');
  if (siteKey.isEmpty) {
    if (kDebugMode) {
      print('RECAPTCHA_SITE_KEY is not defined. Pass it using --dart-define');
    }
  }

  await FirebaseAppCheck.instance.activate(
    webProvider: ReCaptchaV3Provider(siteKey),
  );

  // ★ 削除: アプリ起動時の匿名認証処理はすべて削除します。
  
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
    // ★ 修正: 新しいauthNotifierProviderを監視します。
    final authState = ref.watch(authNotifierProvider);
    final onboardingPrefs = ref.watch(sharedPreferencesProvider);

    switch (authState.status) {
      case AuthStatus.initializing:
        // 認証処理中はローディング画面を表示
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case AuthStatus.error:
        // エラーが発生した場合
        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                '認証に失敗しました。\n${authState.errorMessage}',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      case AuthStatus.signedIn:
      case AuthStatus.signedOut: // signedOutからもオンボーディングチェックへ
        // オンボーディングが完了しているかチェック
        return onboardingPrefs.when(
          loading: () =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
          error: (err, stack) =>
              const Scaffold(body: Center(child: Text('設定の読み込みに失敗しました'))),
          data: (prefs) {
            final onboardingCompleted =
                prefs.getBool('onboarding_completed') ?? false;

            if (!onboardingCompleted) {
              return const OnboardingScreen();
            }
            // オンボーディング完了済みで、サインインも成功していればホームへ
            if (authState.status == AuthStatus.signedIn) {
              return const HomeScreen();
            }
            // このケースは基本発生しないが、念のためローディング表示
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          },
        );
    }
  }
}