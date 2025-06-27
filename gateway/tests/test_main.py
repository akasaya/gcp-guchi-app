import pytest
from gateway.main import app as flask_app
import gateway.main  # モックの呼び出し検証のために追加
import json
import copy
from unittest.mock import Mock, MagicMock # ★★★ 修正: MagicMockを追加 ★★★
from datetime import datetime, timezone

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

MOCK_GRAPH_DATA = {
    "nodes": [{"id": "仕事", "type": "topic", "size": 20}],
    "edges": []
}

MOCK_BOOK_RECOMMENDATIONS = [
    {"title": "Book 1", "author": "Author 1", "reason": "Reason 1", "search_url": "url1"}
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
    response = client.get('/api/')
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
        '/api/session/start',
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
        f'/api/session/{MOCK_SESSION_ID}/swipe',
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
        f'/api/session/{MOCK_SESSION_ID}/summary',
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
        '/api/session/start',
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
        '/api/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({ "not_a_topic": "test" }),
        content_type='application/json'
    )
    assert response.status_code == 400
    assert response.get_json()['error'] == 'Topic is required'

def test_get_analysis_summary_success(client, mocker):
    """
    GET /analysis/summary の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_db = mocker.patch('gateway.main.db_firestore')

    # --- モックデータ ---
    mock_sessions = [
        # 完了したセッション (topicあり)
        MagicMock(to_dict=lambda: {'status': 'completed', 'topic': '仕事'}),
        MagicMock(to_dict=lambda: {'status': 'completed', 'topic': '人間関係'}),
        MagicMock(to_dict=lambda: {'status': 'completed', 'topic': '仕事'}),
        # 完了したがtopicがないデータ (集計から除外されるはず)
        MagicMock(to_dict=lambda: {'status': 'completed'}),
        # 未完了のセッション (クエリで除外されるはず)
        MagicMock(to_dict=lambda: {'status': 'processing', 'topic': '将来'}),
    ]
    
    # --- Firestoreのモック設定 ---
    # where句でフィルタリングされた後のstream()の結果をモックする
    mock_filtered_sessions = [s for s in mock_sessions if s.to_dict().get('status') == 'completed']
    mock_query = MagicMock()
    mock_query.stream.return_value = mock_filtered_sessions
    
    mock_sessions_collection = mock_db.collection.return_value.document.return_value.collection.return_value
    mock_sessions_collection.where.return_value = mock_query

    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/summary',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    data = response.get_json()
    assert data['total_sessions'] == 3
    # 順序は問わないので、リストの中身をソートして比較
    expected_topics = [{'topic': '仕事', 'count': 2}, {'topic': '人間関係', 'count': 1}]
    # topic_countsもtopicでソートして比較
    assert sorted(data['topic_counts'], key=lambda x: x['topic']) == sorted(expected_topics, key=lambda x: x['topic'])


def test_get_analysis_summary_no_data(client, mocker):
    """
    GET /analysis/summary の正常系テスト (データ0件)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_db = mocker.patch('gateway.main.db_firestore')

    # --- Firestoreのモック設定 (データが0件返る) ---
    mock_query = MagicMock()
    mock_query.stream.return_value = []
    
    mock_sessions_collection = mock_db.collection.return_value.document.return_value.collection.return_value
    mock_sessions_collection.where.return_value = mock_query
    
    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/summary',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    data = response.get_json()
    assert data['total_sessions'] == 0
    assert data['topic_counts'] == []

def test_get_analysis_graph_no_cache(client, mocker):
    """
    GET /analysis/graph の正常系テスト (キャッシュ無し)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    
    # --- 依存関数のモック ---
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="仕事の悩みについてのインサイトテキスト。")
    mock_generate_graph = mocker.patch('gateway.main.generate_graph_data', return_value=MOCK_GRAPH_DATA)
    # ベクトル化関連のモック (副作用なので中身は検証しない)
    mocker.patch('gateway.main._get_embeddings', return_value=[[0.1, 0.2]])
    mock_vector_search_index = mocker.patch('gateway.main.aiplatform.MatchingEngineIndex')
    mocker.patch('gateway.main._generate_book_recommendations') # 書籍推薦は別のテストで

    # --- Firestoreキャッシュのモック ---
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_cache_ref = MagicMock()
    mock_cache_doc = MagicMock()
    mock_cache_doc.exists = False # キャッシュは存在しない
    mock_cache_ref.get.return_value = mock_cache_doc
    # analysis_cacheコレクションをモック
    mock_db.collection.return_value.document.return_value = mock_cache_ref

    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/graph',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    assert response.get_json() == MOCK_GRAPH_DATA
    mock_generate_graph.assert_called_once() # グラフ生成が呼ばれた
    mock_cache_ref.set.assert_called_once()  # 新しいキャッシュが保存された
    mock_vector_search_index.return_value.upsert_datapoints.assert_called_once() # Vector Searchへの登録が呼ばれた


def test_get_analysis_graph_with_cache(client, mocker):
    """
    GET /analysis/graph の正常系テスト (キャッシュ有り)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_generate_graph = mocker.patch('gateway.main.generate_graph_data')

    # --- Firestoreキャッシュのモック ---
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_cache_ref = MagicMock()
    mock_cache_doc = MagicMock()
    mock_cache_doc.exists = True # キャッシュが存在する
    mock_cache_doc.to_dict.return_value = {
        'graph_data': MOCK_GRAPH_DATA,
        'timestamp': datetime.now(timezone.utc) # 有効期限内のタイムスタンプ
    }
    mock_cache_ref.get.return_value = mock_cache_doc
    mock_db.collection.return_value.document.return_value = mock_cache_ref
    
    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/graph',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    assert response.get_json() == MOCK_GRAPH_DATA
    mock_generate_graph.assert_not_called() # グラフ生成は呼ばれない
    mock_cache_ref.set.assert_not_called()  # キャッシュの新規保存はされない


def test_get_analysis_graph_no_data(client, mocker):
    """
    GET /analysis/graph の異常系テスト (インサイトデータ無し)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="") # インサイトが空
    mocker.patch('gateway.main.generate_graph_data', return_value=None) # グラフデータも生成されない

    # --- Firestoreキャッシュのモック ---
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_cache_ref = MagicMock()
    mock_cache_doc = MagicMock()
    mock_cache_doc.exists = False
    mock_cache_ref.get.return_value = mock_cache_doc
    mock_db.collection.return_value.document.return_value = mock_cache_ref
    
    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/graph',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 404
    assert response.get_json() == {"error": "No data available to generate graph"}


def test_get_book_recommendations_with_cache(client, mocker):
    """
    GET /analysis/book_recommendations の正常系テスト (キャッシュ有り)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.GOOGLE_BOOKS_API_KEY', 'fake-api-key')

    # --- Firestoreキャッシュのモック ---
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_cache_ref = MagicMock()
    mock_cache_doc = MagicMock()
    mock_cache_doc.exists = True
    mock_cache_doc.to_dict.return_value = {
        'recommendations': MOCK_BOOK_RECOMMENDATIONS
    }
    mock_cache_ref.get.return_value = mock_cache_doc
    # recommendation_cacheコレクションをモック
    mock_db.collection.return_value.document.return_value = mock_cache_ref

    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/book_recommendations',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    assert response.get_json() == MOCK_BOOK_RECOMMENDATIONS


def test_get_book_recommendations_no_cache(client, mocker):
    """
    GET /analysis/book_recommendations の正常系テスト (キャッシュ無し)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.GOOGLE_BOOKS_API_KEY', 'fake-api-key')

    # --- Firestoreキャッシュのモック ---
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_cache_ref = MagicMock()
    mock_cache_doc = MagicMock()
    mock_cache_doc.exists = False # キャッシュなし
    mock_cache_ref.get.return_value = mock_cache_doc
    mock_db.collection.return_value.document.return_value = mock_cache_ref
    
    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/book_recommendations',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    assert response.get_json() == [] # 現在の実装では空リストが返る


def test_get_book_recommendations_no_api_key(client, mocker):
    """
    GET /analysis/book_recommendations の異常系テスト (APIキーなし)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    # GOOGLE_BOOKS_API_KEYがNoneである状況をモック
    mocker.patch('gateway.main.GOOGLE_BOOKS_API_KEY', None)
    
    # --- API呼び出し ---
    response = client.get(
        '/api/analysis/book_recommendations',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 500
    assert response.get_json()['error'] == "Book recommendation service is not configured."


def test_get_topic_suggestion_success(client, mocker):
    """
    GET /session/topic_suggestions の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="ユーザーのインサイトテキスト")
    
    mock_suggestions = ["新しい趣味", "キャリアプラン"]
    mocker.patch('gateway.main.generate_topic_suggestions', return_value=mock_suggestions)

    # --- API呼び出し ---
    response = client.get(
        '/api/session/topic_suggestions',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    assert response.get_json() == {"suggestions": mock_suggestions}


def test_get_topic_suggestion_no_insights(client, mocker):
    """
    GET /session/topic_suggestions の正常系テスト (インサイト無し)
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    # 過去のインサイトが存在しない状況をモック
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="")
    mock_generate = mocker.patch('gateway.main.generate_topic_suggestions')

    # --- API呼び出し ---
    response = client.get(
        '/api/session/topic_suggestions',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    # --- 検証 ---
    assert response.status_code == 200
    assert response.get_json() == {"suggestions": []}
    mock_generate.assert_not_called() # インサイトがないので、提案生成は呼ばれない