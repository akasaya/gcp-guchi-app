import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:flutter_svg/flutter_svg.dart';

@GenerateMocks([
  FirebaseAuth,
  UserCredential,
  User,
  GoogleSignIn,
  GoogleSignInAccount,
  GoogleSignInAuthentication
])
import 'login_screen_test.mocks.dart';

void main() {
  late MockFirebaseAuth mockAuth;
  late MockGoogleSignIn mockGoogleSignIn;
  late MockUserCredential mockUserCredential;

  setUp(() {
    mockAuth = MockFirebaseAuth();
    mockGoogleSignIn = MockGoogleSignIn();
    mockUserCredential = MockUserCredential();
  });

  Future<void> pumpLoginScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LoginScreen(
          auth: mockAuth,
          googleSignIn: mockGoogleSignIn,
          googleWebClientId: 'dummy-client-id-for-test',
        ),
      ),
    );
  }

  group('LoginScreen Widget Tests', () {
    testWidgets('初期表示で必要なウィジェットが表示されていること', (WidgetTester tester) async {
      await pumpLoginScreen(tester);

      // TextFormFieldが2つ（メール、パスワード）
      expect(find.byType(TextFormField), findsNWidgets(2));
      
      // ボタンの検証（UIの変更に合わせて修正）
      expect(find.widgetWithText(ElevatedButton, 'ログイン'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'メールアドレスで新規登録'), findsOneWidget);

      // GoogleロゴのSVGが表示されていること（ボタンの代わり）
      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('有効なメールとパスワードでログインすると成功し、SnackBarが表示されること', (WidgetTester tester) async {
      when(mockAuth.signInWithEmailAndPassword(
        email: 'test@example.com',
        password: 'password123',
      )).thenAnswer((_) async => mockUserCredential);

      await pumpLoginScreen(tester);
      await tester.enterText(find.byType(TextFormField).at(0), 'test@example.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      // ボタンの種別をElevatedButtonに限定してタップ
      await tester.tap(find.widgetWithText(ElevatedButton, 'ログイン'));
      await tester.pumpAndSettle();

      expect(find.text('ログインしました。'), findsOneWidget);
      verify(mockAuth.signInWithEmailAndPassword(
        email: 'test@example.com',
        password: 'password123',
      )).called(1);
    });

    testWidgets('登録されていない情報でログインすると失敗し、エラーメッセージが表示されること', (WidgetTester tester) async {
      when(mockAuth.signInWithEmailAndPassword(
        email: 'nouser@example.com',
        password: 'password123',
      )).thenThrow(FirebaseAuthException(code: 'user-not-found'));

      await pumpLoginScreen(tester);
      await tester.enterText(find.byType(TextFormField).at(0), 'nouser@example.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'password123');
      await tester.tap(find.widgetWithText(ElevatedButton, 'ログイン'));
      await tester.pumpAndSettle();

      expect(find.text('メールアドレスまたはパスワードが間違っています。'), findsOneWidget);
    });

    testWidgets('有効なメールとパスワードで新規登録すると成功し、SnackBarが表示されること', (WidgetTester tester) async {
      when(mockAuth.createUserWithEmailAndPassword(
        email: 'new.user@example.com',
        password: 'new-password-123',
      )).thenAnswer((_) async => mockUserCredential);
      
      await pumpLoginScreen(tester);
      await tester.enterText(find.byType(TextFormField).at(0), 'new.user@example.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'new-password-123');
      // ボタンの種別をOutlinedButtonに限定してタップ
      await tester.tap(find.widgetWithText(OutlinedButton, 'メールアドレスで新規登録'));
      await tester.pumpAndSettle();

      expect(find.text('新規登録に成功しました。'), findsOneWidget);
       verify(mockAuth.createUserWithEmailAndPassword(
        email: 'new.user@example.com',
        password: 'new-password-123',
      )).called(1);
    });
    
    testWidgets('Googleログインボタンをタップすると、Googleのサインイン処理が呼ばれること', (WidgetTester tester) async {
      final mockGoogleSignInAccount = MockGoogleSignInAccount();
      final mockGoogleSignInAuthentication = MockGoogleSignInAuthentication();

      when(mockGoogleSignIn.signIn()).thenAnswer((_) async => mockGoogleSignInAccount);
      when(mockGoogleSignInAccount.authentication).thenAnswer((_) async => mockGoogleSignInAuthentication);
      when(mockGoogleSignInAuthentication.accessToken).thenReturn('dummy_access_token');
      when(mockGoogleSignInAuthentication.idToken).thenReturn('dummy_id_token');
      when(mockAuth.signInWithCredential(any)).thenAnswer((_) async => mockUserCredential);

      await pumpLoginScreen(tester);
      // GoogleロゴのSVGをタップするように修正
      await tester.tap(find.byType(SvgPicture));
      await tester.pumpAndSettle();

      verify(mockAuth.signInWithCredential(any)).called(1);
      expect(find.text('Googleアカウントでログインしました。'), findsOneWidget);
    });
  });
}