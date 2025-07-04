import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart'; 
import 'package:flutter_svg/flutter_svg.dart';

class LoginScreen extends StatefulWidget {
  final FirebaseAuth? auth;
  final GoogleSignIn? googleSignIn;
  final String? googleWebClientId;

  const LoginScreen({
    super.key,
    this.auth,
    this.googleSignIn,
    this.googleWebClientId,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final FirebaseAuth _auth;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  String _email = '';
  String _password = '';
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _auth = widget.auth ?? FirebaseAuth.instance;
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final webClientId = widget.googleWebClientId;
      if (webClientId == null || webClientId.isEmpty) {
        if (mounted) {
          setState(() {
            _errorMessage = 'クライアントIDがビルド時に設定されていません。';
            _isLoading = false;
          });
        }
        return;
      }

      final GoogleSignIn effectiveGoogleSignIn = widget.googleSignIn ?? GoogleSignIn(clientId: webClientId);
      final GoogleSignInAccount? googleUser = await effectiveGoogleSignIn.signIn();

      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await _auth.signInWithCredential(credential);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Googleアカウントでログインしました。')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Googleログインに失敗しました: ${e.message}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'ログイン処理中にエラーが発生しました。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    _formKey.currentState!.save();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _auth.createUserWithEmailAndPassword(
        email: _email,
        password: _password,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('新規登録に成功しました。')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          if (e.code == 'weak-password') {
            _errorMessage = 'パスワードが弱すぎます。';
          } else if (e.code == 'email-already-in-use') {
            _errorMessage = 'このメールアドレスは既に使用されています。';
          } else if (e.code == 'invalid-email') {
            _errorMessage = '無効なメールアドレスです。';
          }
           else {
            _errorMessage = '新規登録に失敗しました: ${e.message}';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '予期せぬエラーが発生しました: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    _formKey.currentState!.save();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _auth.signInWithEmailAndPassword(
        email: _email,
        password: _password,
      );
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ログインしました。')),
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() {
          if (e.code == 'user-not-found' || e.code == 'wrong-password' || e.code == 'invalid-credential') {
             _errorMessage = 'メールアドレスまたはパスワードが間違っています。';
          } else if (e.code == 'invalid-email') {
            _errorMessage = '無効なメールアドレスです。';
          }
          else {
            _errorMessage = 'ログインに失敗しました: ${e.message}';
          }
        });
      }
    } catch (e) {
       if (mounted) {
        setState(() {
          _errorMessage = '予期せぬエラーが発生しました: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ログイン / 新規登録')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'メールアドレス'),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      if (value == null || value.isEmpty || !value.contains('@')) {
                        return '有効なメールアドレスを入力してください。';
                      }
                      return null;
                    },
                    onSaved: (value) {
                      _email = value!;
                    },
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    decoration: const InputDecoration(labelText: 'パスワード (6文字以上)'),
                    obscureText: true,
                    validator: (value) {
                      if (value == null || value.isEmpty || value.length < 6) {
                        return 'パスワードは6文字以上で入力してください。';
                      }
                      return null;
                    },
                    onSaved: (value) {
                      _password = value!;
                    },
                  ),
                  const SizedBox(height: 30),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (_isLoading)
                    const CircularProgressIndicator()
                  else
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ElevatedButton(
                            onPressed: _login,
                            child: const Text('ログイン'),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: _register,
                            child: const Text('メールアドレスで新規登録'),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            children: [
                              const Expanded(child: Divider()),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8.0),
                                child: Text(
                                  'または',
                                  style: TextStyle(color: Colors.grey.shade600),
                                ),
                              ),
                              const Expanded(child: Divider()),
                            ],
                          ),
                          const SizedBox(height: 20),
                          GestureDetector(
                            onTap: _signInWithGoogle,
                            child: SvgPicture.asset(
                              'assets/google_logo.svg',
                              height: 48.0,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}