import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:frontend/screens/onboarding_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

final firebaseAuthProvider =
    Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

// ★ 追加: SharedPreferences のインスタンスを非同期で提供する Provider
final sharedPreferencesProvider =
    FutureProvider<SharedPreferences>((ref) async {
  return await SharedPreferences.getInstance();
});

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
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
      // ★ 修正: AuthWrapperを呼び出すように変更
      home: const AuthWrapper(),
    );
  }
}

// ★ 追加: 認証状態とオンボーディング状態に応じて画面を振り分けるWidget
class AuthWrapper extends ConsumerWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(firebaseAuthProvider);
    final onboardingPrefs = ref.watch(sharedPreferencesProvider);

    return onboardingPrefs.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (err, stack) =>
          const Scaffold(body: Center(child: Text('エラーが発生しました'))),
      data: (prefs) {
        final onboardingCompleted =
            prefs.getBool('onboarding_completed') ?? false;

        if (!onboardingCompleted) {
          return const OnboardingScreen();
        }

        return StreamBuilder<User?>(
          stream: auth.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                  body: Center(child: CircularProgressIndicator()));
            }
            if (snapshot.hasData) {
              return const HomeScreen();
            }
            return const LoginScreen();
          },
        );
      },
    );
  }
}