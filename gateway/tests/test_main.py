import pytest
from gateway.main import app as flask_app
import gateway.main  # モックの呼び出し検証のために追加
import json
import copy

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
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.generate_initial_questions', return_value=copy.deepcopy(MOCK_QUESTIONS))
    
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_batch = mock_db.batch.return_value

    mock_session_doc_ref = mocker.Mock()
    mock_session_doc_ref.id = "test_session_id_123"
    
    mock_q_doc_1, mock_q_doc_2 = mocker.Mock(), mocker.Mock()
    mock_q_doc_1.id, mock_q_doc_2.id = "q_id_0", "q_id_1"

    # db.collection('sessions').document() が mock_session_doc_ref を返す
    mock_db.collection.return_value.document.return_value = mock_session_doc_ref
    # session_doc_ref.collection('questions').document() が q_id_0, q_id_1 を順番に返す
    mock_session_doc_ref.collection.return_value.document.side_effect = [mock_q_doc_1, mock_q_doc_2]

    response = client.post(
        '/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({'topic': '仕事の悩み'}),
        content_type='application/json'
    )

    assert response.status_code == 200, f"API failed with response: {response.get_data(as_text=True)}"
    response_data = response.get_json()
    assert response_data['session_id'] == "test_session_id_123"
    assert response_data['questions'][0]['question_id'] == "q_id_0"
    mock_batch.commit.assert_called_once()
    assert mock_batch.set.call_count == len(MOCK_QUESTIONS)

def test_record_swipe_success(client, mocker):
    """
    POST /session/<session_id>/swipe の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_swipe_set = mocker.Mock()
    # db.collection(...).document(...).collection(...).document().set をモック
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value.set = mock_swipe_set

    swipe_data = {
        "question_id": "q_id_0", 
        "answer": True, 
        "turn": 1,
        "hesitation_time": 0.8,
        "speed": 500.0
    }
    
    response = client.post(
        f'/session/test_session_id_123/swipe',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps(swipe_data),
        content_type='application/json'
    )

    assert response.status_code == 200
    assert response.get_json()['status'] == 'success'
    mock_swipe_set.assert_called_once()

def test_post_summary_success(client, mocker):
    """
    POST /session/<session_id>/summary の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.generate_summary_only', return_value=MOCK_SUMMARY_DATA)
    mocker.patch('gateway.main.threading.Thread')

    mock_db = mocker.patch('gateway.main.db_firestore')

    mock_session_snapshot = mocker.Mock()
    mock_session_snapshot.exists = True
    mock_session_snapshot.to_dict.return_value = {'topic': '仕事の悩み', 'turn': 1}
    mock_session_doc_ref = mocker.Mock()
    mock_session_doc_ref.get.return_value = mock_session_snapshot

    mock_swipe_doc = mocker.Mock()
    mock_swipe_doc.to_dict.return_value = {"question_id": "q_id_0", "answer": True, "hesitation_time": 1.0}
    
    # db.collection(...).document(...) がセッションドキュメントのモックを返す
    mock_db.collection.return_value.document.return_value = mock_session_doc_ref
    # session_ref.collection(...).order_by(...).stream() がスワイプ履歴のモックを返す
    mock_session_doc_ref.collection.return_value.order_by.return_value.stream.return_value = [mock_swipe_doc]

    response = client.post(
        f'/session/test_session_id_123/summary',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({}), # リクエストボディは実際には使われない
        content_type='application/json'
    )

    assert response.status_code == 200, f"API failed: {response.get_data(as_text=True)}"
    assert response.get_json()['title'] == MOCK_SUMMARY_DATA['title']
    mock_session_doc_ref.update.assert_called_once()
    # (★★★ 修正: 呼び出されるスレッドは1つになったので、期待値を1に変更 ★★★)
    assert gateway.main.threading.Thread.call_count == 1

def test_start_session_auth_error(client, mocker):
    """
    POST /session/start の認証エラーテスト
    """
    from firebase_admin import auth
    mocker.patch('firebase_admin.auth.verify_id_token', side_effect=auth.InvalidIdTokenError("Test token is invalid"))

    response = client.post(
        '/session/start',
        headers={'Authorization': 'Bearer invalid_token'},
        data=json.dumps({'topic': '仕事の悩み'}),
        content_type='application/json'
    )
    assert response.status_code == 401
    assert response.get_json()['error'] == 'Invalid or expired token'

def test_start_session_missing_topic(client, mocker):
    """
    POST /session/start のバリデーションエラーテスト (トピックなし)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    response = client.post(
        '/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({ "not_a_topic": "test" }),
        content_type='application/json'
    )
    assert response.status_code == 400
    assert response.get_json()['error'] == 'Topic is required'