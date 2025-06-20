import pytest
from gateway.main import app as flask_app
import gateway.main  # モックの呼び出し検証のために追加
import json

# --- モックデータ ---
MOCK_USER_ID = "test_user_123"
MOCK_ID_TOKEN = "mock_firebase_id_token"
MOCK_QUESTIONS = [
    {"question_text": "質問1ですか？"},
    {"question_text": "質問2ですか？"},
]
MOCK_SUMMARY_DATA = {
    "title": "仕事の悩みについての考察",
    "insights": "### ✨ 全体的な要約\nユーザーは仕事のプレッシャーを感じています..."
}

@pytest.fixture
def app():
    flask_app.config.update({
        "TESTING": True,
    })
    yield flask_app

@pytest.fixture
def client(app):
    """A test client for the app."""
    return app.test_client()

def test_index_route(client):
    """Test the index route."""
    response = client.get('/')
    assert response.status_code == 200
    assert b"GuchiSwipe Gateway is running." in response.data

def test_start_session_success(client, mocker):
    """
    POST /session/start の正常系テスト
    - 外部API呼び出しをモックする
    - 正常なレスポンス (200 OK) と期待されるデータが返ることを確認
    """
    # --- モックの設定 ---
    # 認証とGeminiをモック
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.generate_initial_questions', return_value=MOCK_QUESTIONS)

    # --- Firestoreの呼び出しチェーン全体をモック (★★★ 修正: db_firestore自体をモックする ★★★) ---
    mock_db = mocker.patch('gateway.main.db_firestore')

    # 1. 最終的にコード中で使われることになる、末端のドキュメント参照を準備
    # これが /users/{uid}/sessions/{sid} に対応する
    mock_session_doc_ref = mocker.Mock()
    mock_session_doc_ref.id = "test_session_id_123"

    # これが /users/{uid}/sessions/{sid}/questions/{qid} に対応する (ループで使われる)
    mock_question_doc_refs = [mocker.Mock(id=f"q_id_{i}") for i in range(len(MOCK_QUESTIONS))]

    # 2. `db_firestore.collection()...` という呼び出しチェーンの結果として、
    #    上で準備した `mock_session_doc_ref` が返るように設定
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_doc_ref

    # 3. `session_doc_ref` の後に行われる処理をモック
    #    `session_doc_ref.collection('questions')` が呼ばれたら、質問コレクションのモックを返す
    mock_questions_collection = mocker.Mock()
    mock_session_doc_ref.collection.return_value = mock_questions_collection

    #    `questions_collection.document()` が呼ばれるたびに、準備した質問ドキュメントのモックを順番に返す
    mock_questions_collection.document.side_effect = mock_question_doc_refs

    # --- API呼び出し ---
    response = client.post(
        '/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({'topic': '仕事の悩み'}),
        content_type='application/json'
    )

    # --- 検証 ---
    assert response.status_code == 200, f"API failed with response: {response.get_data(as_text=True)}"
    response_data = response.get_json()
    assert response_data['session_id'] == "test_session_id_123"
    assert len(response_data['questions']) == len(MOCK_QUESTIONS)
    assert response_data['questions'][0]['question_id'] == "q_id_0"

    # --- モックの呼び出し検証 ---
    gateway.main.generate_initial_questions.assert_called_once_with(topic='仕事の悩み')
    mock_session_doc_ref.set.assert_called_once()
    assert mock_questions_collection.document.call_count == len(MOCK_QUESTIONS)
    for mock_doc in mock_question_doc_refs:
        mock_doc.set.assert_called_once()

def test_record_swipe_success(client, mocker):
    """
    POST /session/<session_id>/swipe の正常系テスト
    """
    # --- モックの設定 ---
    # 認証をモック
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # Firestoreの .add() メソッドを、呼び出しチェーン全体を模倣してモックする (★★★ 修正: db_firestore自体をモックする ★★★)
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_add = mocker.Mock()
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value.collection.return_value.add = mock_add


    # --- API呼び出し ---
    session_id = "test_session_id_123"
    swipe_data = {
        "question_id": "q_id_0",
        "answer": True,
        "hesitation_time": 1.2,
        "speed": 300,
        "turn": 1
    }
    response = client.post(
        f'/session/{session_id}/swipe',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps(swipe_data),
        content_type='application/json'
    )

    # --- 検証 ---
    assert response.status_code == 200, f"API failed with response: {response.get_data(as_text=True)}"
    assert response.get_json()['status'] == 'swipe_recorded'

    # Firestoreへの書き込みが1回呼ばれたことを検証
    mock_add.assert_called_once()

    # 書き込まれたデータの内容を検証
    added_data = mock_add.call_args[0][0]
    assert added_data['question_id'] == swipe_data['question_id']
    assert added_data['answer'] == swipe_data['answer']
    assert added_data['turn'] == swipe_data['turn']

def test_post_summary_success(client, mocker):
    """
    POST /session/<session_id>/summary の正常系テスト
    """
    # --- モックの設定 ---
    # 認証、Gemini、バックグラウンドスレッドをまとめてモック
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.generate_summary_only', return_value=MOCK_SUMMARY_DATA)
    mocker.patch('gateway.main.threading.Thread')

    # Firestoreの呼び出しをモック (★★★ 修正: db_firestore自体をモックする ★★★)
    mock_db = mocker.patch('gateway.main.db_firestore')
    
    # .get() が返すドキュメントスナップショットのモック
    mock_snapshot = mocker.Mock()
    mock_snapshot.exists = True
    mock_snapshot.to_dict.return_value = {'topic': '仕事の悩み', 'turn': 1, 'max_turns': 3}

    # セッションドキュメント参照のモックを作成し、振る舞いを定義
    mock_session_doc_ref = mocker.Mock()
    mock_session_doc_ref.get.return_value = mock_snapshot
    mock_analyses_add = mock_session_doc_ref.collection.return_value.add # .add メソッドを直接モック

    # 実際の呼び出しチェーンが、作成したモックを返すようにパッチを適用
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_doc_ref

    # --- API呼び出し ---
    session_id = "test_session_id_123"
    request_body = { "swipes": [{"question_text": "Q1", "answer": True}] }
    response = client.post(
        f'/session/{session_id}/summary',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps(request_body),
        content_type='application/json'
    )

    # --- 検証 ---
    assert response.status_code == 200, f"API failed: {response.get_data(as_text=True)}"
    response_data = response.get_json()
    assert response_data['title'] == MOCK_SUMMARY_DATA['title']
    assert response_data['insights'] == MOCK_SUMMARY_DATA['insights']

    # --- モックの呼び出し検証 ---
    swipes_text = "\n".join([f"Q: {s.get('question_text')}\nA: {'はい' if s.get('answer') else 'いいえ'}" for s in request_body['swipes']])
    gateway.main.generate_summary_only.assert_called_once_with(topic='仕事の悩み', swipes_text=swipes_text)
    
    mock_analyses_add.assert_called_once()
    mock_session_doc_ref.update.assert_called_once()
    
    update_data = mock_session_doc_ref.update.call_args[0][0]
    assert update_data['status'] == 'completed'
    assert update_data['title'] == MOCK_SUMMARY_DATA['title']

    assert gateway.main.threading.Thread.call_count == 2

def test_start_session_auth_error(client, mocker):
    """
    POST /session/start の認証エラーテスト
    - _verify_token が例外を発生させた場合に 403 Forbidden が返ることを確認
    """
    # --- モックの設定 ---
    # (★★★ 修正: _verify_token自体ではなく、内部で呼ばれるauth.verify_id_tokenをモックする ★★★)
    from firebase_admin import auth
    # これにより、_verify_token内のtry-exceptブロックが機能し、適切なエラーレスポンスが生成される
    mocker.patch('firebase_admin.auth.verify_id_token', side_effect=auth.InvalidIdTokenError("Test token is invalid"))

    # --- API呼び出し ---
    response = client.post(
        '/session/start',
        headers={'Authorization': 'Bearer invalid_token'},
        data=json.dumps({'topic': '仕事の悩み'}),
        content_type='application/json'
    )

    # --- 検証 ---
    assert response.status_code == 403, f"Expected 403, but got {response.status_code}. Response: {response.get_data(as_text=True)}"
    response_data = response.get_json()
    assert 'error' in response_data
    assert response_data['error'] == 'Invalid or expired token'

def test_start_session_missing_topic(client, mocker):
    """
    POST /session/start のバリデーションエラーテスト (トピックなし)
    - リクエストボディに topic がない場合に 400 Bad Request が返ることを確認
    """
    # 認証をモックしておく（バリデーションが先に行われるので、このモックは呼ばれないはず）
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # --- API呼び出し ---
    response = client.post(
        '/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({ "not_a_topic": "test" }), # 'topic' キーを含まないリクエスト
        content_type='application/json'
    )

    # --- 検証 ---
    assert response.status_code == 400
    response_data = response.get_json()
    assert response_data['error'] == 'Topic is required'