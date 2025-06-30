import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

// 認証の状態を表すenum
enum AuthStatus {
  initializing,
  signedIn,
  signedOut,
  error,
}

// 認証状態とユーザー情報を保持するクラス
class AuthState {
  final AuthStatus status;
  final User? user;
  final String? errorMessage;

  AuthState({required this.status, this.user, this.errorMessage});
}

// 認証ロジックを管理するStateNotifier
class AuthNotifier extends StateNotifier<AuthState> {
  final FirebaseAuth _auth;

  AuthNotifier(this._auth) : super(AuthState(status: AuthStatus.initializing)) {
    _init();
  }

  Future<void> _init() async {
    try {
      // 永続化されたユーザーセッションの復元を待つ
      await _auth.authStateChanges().first;

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        // ユーザーがいなければ、匿名サインインを試みる
        if (kDebugMode) {
          print("No user found, attempting to sign in anonymously...");
        }
        final userCredential = await _auth.signInAnonymously();
        state = AuthState(status: AuthStatus.signedIn, user: userCredential.user);
        if (kDebugMode) {
          print("Signed in anonymously successfully with UID: ${userCredential.user?.uid}");
        }
      } else {
        // ユーザーが見つかった
        state = AuthState(status: AuthStatus.signedIn, user: currentUser);
        if (kDebugMode) {
          print("User restored successfully with UID: ${currentUser.uid}");
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print("Error during auth initialization: $e");
      }
      state = AuthState(status: AuthStatus.error, errorMessage: e.toString());
    }
  }
}

// FirebaseAuthのインスタンスを提供
final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

// AuthNotifierを提供
final authNotifierProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final auth = ref.watch(firebaseAuthProvider);
  return AuthNotifier(auth);
});