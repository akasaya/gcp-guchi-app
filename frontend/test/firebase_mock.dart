import 'package:firebase_core_platform_interface/firebase_core_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Callback = void Function(MethodCall call);

void setupFirebaseMocks([Callback? customHandlers]) {
  // テスト用のBindingを確実に初期化し、インスタンスを取得します。
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  // 取得したBinding経由で、テスト用のメッセンジャーにアクセスします。
  // これが現在のFlutterで推奨されている方法です。
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/firebase_core'),
    (MethodCall call) async {
      if (call.method == 'Firebase#initializeCore') {
        return {
          'name': defaultFirebaseAppName,
          'options': {
            'apiKey': 'mock_api_key',
            'appId': 'mock_app_id',
            'messagingSenderId': 'mock_sender_id',
            'projectId': 'mock_project_id',
          },
          'pluginConstants': <String, dynamic>{},
        };
      }

      if (call.method == 'Firebase#apps') {
        return [
          {
            'name': defaultFirebaseAppName,
            'options': {
              'apiKey': 'mock_api_key',
              'appId': 'mock_app_id',
              'messagingSenderId': 'mock_sender_id',
              'projectId': 'mock_project_id',
            },
            'pluginConstants': <String, dynamic>{},
          }
        ];
      }

      if (customHandlers != null) {
        customHandlers(call);
      }

      return null;
    },
  );
}