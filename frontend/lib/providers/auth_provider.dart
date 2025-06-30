import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

// FirebaseAuthのインスタンスを提供
final firebaseAuthProvider = Provider<FirebaseAuth>((ref) => FirebaseAuth.instance);

// 認証状態のストリームを提供するProvider
// Firebaseの認証状態が変更されると、このProviderが新しい値(User? or null)を流します。
final authStateChangesProvider = StreamProvider<User?>((ref) {
  return ref.watch(firebaseAuthProvider).authStateChanges();
});

// ログアウト機能などを提供するProvider
final authServiceProvider = Provider((ref) {
  return AuthService(ref.watch(firebaseAuthProvider));
});

class AuthService {
  final FirebaseAuth _auth;
  AuthService(this._auth);

  Future<void> signOut() async {
    // Googleサインインからもログアウトさせるのが親切です。
    await GoogleSignIn().signOut();
    await _auth.signOut();
  }
}