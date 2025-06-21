import pytest
from gateway.main import app as flask_app
import gateway.main  # モックの呼び出し検証のために追加
import json
import copy
from unittest.mock import Mock, MagicMock # ★★★ 修正: MagicMockを追加 ★★★

# --- モックデータ ---
MOCK_USER_ID = "test_user_123"
MOCK_ID_TOKEN = "mock_firebase_id_token"
# ★★★ 修正: MOCK_SESSION_IDを追加 ★★★
MOCK_SESSION_ID = "test_session_id_123" 
MOCK_QUESTIONS = [
    {"question_text": "質問1ですか？", "question_id": "q_id_0"},
    {"question_text": "質問2ですか？", "question_id": "q_id_1"},
]
# ★★★ 修正: MOCK_SUMMARY_DATAを追加 ★★★
MOCK_SUMMARY_DATA = {
    "title": "テスト要約タイトル",
    "insights": "テストインサイトです。"
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
    # ★★★ 修正: generate_initial_questionsが返すデータ形式を実際のコードに合わせる
    mocker.patch('gateway.main.generate_initial_questions', return_value=[{'question_text': q['question_text']} for q in MOCK_QUESTIONS])
    
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_batch = mock_db.batch.return_value

    mock_session_doc_ref = MagicMock()
    mock_session_doc_ref.id = MOCK_SESSION_ID
    
    mock_q_doc_1, mock_q_doc_2 = MagicMock(), MagicMock()
    mock_q_doc_1.id, mock_q_doc_2.id = "q_id_0", "q_id_1"

    # ★★★ 修正: users/{uid}/sessions/{sid} という深いパスをモックする ★★★
    mock_sessions_collection = mock_db.collection.return_value.document.return_value.collection.return_value
    mock_sessions_collection.document.return_value = mock_session_doc_ref
    mock_session_doc_ref.collection.return_value.document.side_effect = [mock_q_doc_1, mock_q_doc_2]

    response = client.post(
        '/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({'topic': '仕事の悩み'}),
        content_type='application/json'
    )

    assert response.status_code == 200, f"API failed with response: {response.get_data(as_text=True)}"
    response_data = response.get_json()
    assert response_data['session_id'] == MOCK_SESSION_ID
    assert response_data['questions'][0]['question_id'] == "q_id_0"
    
    # ★★★ 修正: 呼び出し検証をより正確にする ★★★
    mock_session_doc_ref.set.assert_called_once()
    mock_batch.commit.assert_called_once()
    assert mock_batch.set.call_count == len(MOCK_QUESTIONS)


def test_record_swipe_success(client, mocker):
    """
    POST /session/<session_id>/swipe の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    
    mock_db = mocker.patch('gateway.main.db_firestore')
    
    # ★★★ 修正: users/{uid}/sessions/{sid}/swipes/{swipe_id} という深いパスをモックする ★★★
    mock_swipe_ref = mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value.collection.return_value.document.return_value

    swipe_data = {
        "question_id": "q_id_0", 
        "answer": True, 
        "turn": 1,
        "hesitation_time": 0.8,
        "speed": 500.0
    }
    
    response = client.post(
        f'/session/{MOCK_SESSION_ID}/swipe',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps(swipe_data),
        content_type='application/json'
    )

    assert response.status_code == 200
    assert response.get_json()['status'] == 'success'
    mock_swipe_ref.set.assert_called_once()


def test_post_summary_success(client, mocker):
    """
    POST /session/<session_id>/summary の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.generate_summary_only', return_value=MOCK_SUMMARY_DATA)
    # 以前のthreading.Thread.startのモックを、_create_cloud_taskのモックに置き換える
    mock_create_task = mocker.patch('gateway.main._create_cloud_task')

    mock_db = mocker.patch('gateway.main.db_firestore')

    # --- sessionドキュメントのモック ---
    mock_session_snapshot = MagicMock()
    mock_session_snapshot.exists = True
    mock_session_snapshot.to_dict.return_value = {'topic': '仕事の悩み', 'turn': 1}
    mock_session_doc_ref = MagicMock()
    mock_session_doc_ref.get.return_value = mock_session_snapshot

    # ★★★ 修正: users/{uid}/sessions/{sid} のパスをモックする ★★★
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_doc_ref

    # --- swipesサブコレクションのモック ---
    mock_swipe_doc = MagicMock()
    mock_swipe_doc.to_dict.return_value = {"question_id": "q_id_0", "answer": True, "hesitation_time": 1.0}
    mock_swipes_query = MagicMock()
    # ★★★ 修正: stream()がリストを返すようにする
    mock_swipes_query.stream.return_value = [mock_swipe_doc]

    # --- questionsサブコレクションのモック ---
    mock_question_doc = MagicMock()
    mock_question_doc.id = "q_id_0"
    mock_question_doc.to_dict.return_value = {"question_text": "質問1ですか？"}
    mock_questions_query = MagicMock()
    mock_questions_query.stream.return_value = [mock_question_doc]
    
    # ★★★ 修正: .collection()が呼ばれるたびに、正しいモックを返すように設定 ★★★
    def collection_side_effect(name):
        if name == 'swipes':
            return mock_swipes_query
        elif name == 'questions':
            return mock_questions_query
        elif name == 'summaries': # summariesへの書き込みもモック
            return MagicMock()
        return MagicMock() # その他のコレクション呼び出し
    
    mock_session_doc_ref.collection.side_effect = collection_side_effect
    mock_swipes_query.order_by.return_value = mock_swipes_query # order_by().stream()のチェインを可能にする

    response = client.post(
        f'/session/{MOCK_SESSION_ID}/summary',
        headers={'Authorization': f'***'},
        content_type='application/json'
    )

    assert response.status_code == 200, f"API failed: {response.get_data(as_text=True)}"
    
    # Cloud Tasksの作成関数が2回呼ばれたことを確認
    # 1回目: 質問のプリフェッチ, 2回目: グラフの更新
    assert mock_create_task.call_count == 2


def test_start_session_auth_error(client, mocker):
    """
    POST /session/start の認証エラーテスト
    """
    # ★★★ 修正: _verify_tokenが返すレスポンスをモックする方がより正確 ★★★
    mock_response = flask_app.response_class(
        response=json.dumps({"error": "Invalid or expired token"}),
        status=401,
        mimetype='application/json'
    )
    mocker.patch('gateway.main._verify_token', return_value=mock_response)

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