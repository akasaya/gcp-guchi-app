import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'package:frontend/screens/home_screen.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

// test/widget_test.dart からも参照されるため、グローバルに定義します
final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

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

// ★★★ ここが重要です: StatelessWidget を ConsumerWidget に変更します ★★★
class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  // ★★★ buildメソッドに WidgetRef ref を追加します ★★★
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    // `ref.watch` を使うことで、Providerからインスタンスを取得できます
    final auth = ref.watch(firebaseAuthProvider);

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
      home: StreamBuilder<User?>(
        // Providerから取得したインスタンスを使用
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
      ),
    );
  }
}