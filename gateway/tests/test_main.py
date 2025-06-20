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

    # --- Firestoreの呼び出しチェーン全体をモック (★★★ 全面的に修正 ★★★) ---

    # 1. 最終的にコード中で使われることになる、末端のドキュメント参照を準備
    # これが /users/{uid}/sessions/{sid} に対応する
    mock_session_doc_ref = mocker.Mock()
    mock_session_doc_ref.id = "test_session_id_123"

    # これが /users/{uid}/sessions/{sid}/questions/{qid} に対応する (ループで使われる)
    mock_question_doc_refs = [mocker.Mock(id=f"q_id_{i}") for i in range(len(MOCK_QUESTIONS))]

    # 2. `db_firestore.collection().document().collection().document()` という
    #    長い呼び出しチェーンの結果として、上で準備した `mock_session_doc_ref` が返るように設定
    mocker.patch('gateway.main.db_firestore.collection').return_value.document.return_value.collection.return_value.document.return_value = mock_session_doc_ref

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
