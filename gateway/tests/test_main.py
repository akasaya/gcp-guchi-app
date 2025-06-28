import pytest
from gateway.main import app as flask_app
import gateway.main  # モックの呼び出し検証のために追加
import json
import copy
from unittest.mock import Mock, MagicMock, patch # ★★★ 修正: MagicMockを追加 ★★★
from datetime import datetime, timezone, timedelta # ★★★ 修正: timedeltaを追加 ★★★
import firebase_admin # ★★★ firebase_adminをインポート ★★★
import os # ★★★ osをインポート ★★★
import tenacity # ★★★ tenacityをインポート ★★★
import requests # ★★★ requestsをインポート ★★★
from gateway.main import RAG_CACHE_TTL_DAYS 
from google.auth import credentials as auth_credentials

@pytest.fixture(scope='session', autouse=True)
def mock_gcp_auth(session_mocker):
    """
    CI環境で 'google.auth.default' が認証エラーになるのを防ぐための自動実行フィクスチャ。
    テストセッションの開始時に一度だけ実行され、認証をモックします。
    """
    # google.auth.default() が返すcredentialsオブジェクトを、
    # 正しい型(spec)を持つようにモックする
    mock_creds = MagicMock(spec=auth_credentials.Credentials)
    mock_project_id = "test-project-from-mock"
    session_mocker.patch(
        'google.auth.default',
        return_value=(mock_creds, mock_project_id)
    )

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


def test_cloud_tasks_initialization_success(mocker):
    """
    Cloud Tasksが正常に初期化されるかのテスト（環境変数が全て設定されている場合）
    """

    # 必要な環境変数をモック
    mock_env = {
        'K_SERVICE': 'test-service',
        'GCP_TASK_QUEUE': 'test-queue',
        'GCP_TASK_QUEUE_LOCATION': 'test-location',
        'GCP_TASK_SA_EMAIL': 'test-sa@example.com',
        'K_SERVICE_URL': 'https://test-service-url.com'
    }
    mocker.patch.dict('os.environ', mock_env)
    
    # CloudTasksClientのコンストラクタ自体をモック
    mock_tasks_client = mocker.patch('gateway.main.tasks_v2.CloudTasksClient')

    # mainモジュールを再読み込みして、トップレベルのコードを実行させる
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        
        # 初期化成功のログが出力されたことを確認
        mock_tasks_client.assert_called_once()
        mock_print.assert_any_call("✅ Cloud Tasks client initialized. Queue: test-queue in test-location")

def test_cloud_tasks_initialization_exception(mocker):
    """
    Cloud Tasksの初期化が例外を発生させた場合のテスト
    """


    # 必要な環境変数はすべて設定
    mock_env = {
        'K_SERVICE': 'test-service',
        'GCP_TASK_QUEUE': 'test-queue',
        'GCP_TASK_QUEUE_LOCATION': 'test-location',
        'GCP_TASK_SA_EMAIL': 'test-sa@example.com',
        'K_SERVICE_URL': 'https://test-service-url.com'
    }
    mocker.patch.dict('os.environ', mock_env)
    
    # CloudTasksClientのコンストラクタが例外を投げるようにモック
    mocker.patch('gateway.main.tasks_v2.CloudTasksClient', side_effect=Exception("Test Exception"))
    mocker.patch('traceback.print_exc') # traceback.print_excもモックしておく

    # mainモジュールを再読み込み
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        
        # 初期化失敗のログが出力されたことを確認
        mock_print.assert_any_call("❌ Failed to initialize Cloud Tasks client, even though variables were set: Test Exception")

def test_google_books_api_key_loading_from_secret(mocker):
    """
    Google Books APIキーがSecret Managerから正常に読み込まれるかのテスト
    """


    # os.path.existsとopenをモックする
    mocker.patch('os.path.exists', return_value=True)
    # openのモックは、read()メソッドを持つオブジェクトを返すように設定
    mocker.patch('builtins.open', mocker.mock_open(read_data='test_api_key_from_secret'))

    # mainモジュールを再読み込みして初期化コードを実行
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)

        # グローバル変数にキーが設定されたかを確認
        assert gateway.main.GOOGLE_BOOKS_API_KEY == 'test_api_key_from_secret'
        mock_print.assert_any_call("✅ Loaded Google Books API key from Secret Manager.")


def test_cloud_tasks_initialization_missing_vars(mocker):
    """
    Cloud Tasksが無効になるかのテスト（環境変数が不足している場合）
    """
    # ★★★ 既存のアプリをクリーンアップ ★★★


    # 一部の環境変数だけをモック
    mock_env = {
        'K_SERVICE': 'test-service',
        'GCP_TASK_QUEUE': 'test-queue',
        # 他の変数は設定しない
    }
    mocker.patch.dict('os.environ', mock_env)
    
    # mainモジュールを再読み込み
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        
        # 初期化が無効になった旨の警告ログが出力されたことを確認
        # ★★★ 修正: 出力されるメッセージを実際のコードと完全に一致させる ★★★
        expected_message = "⚠️ Cloud Tasks is disabled. Missing environment variables: GCP_TASK_QUEUE_LOCATION, GCP_TASK_SA_EMAIL, K_SERVICE_URL. Background tasks will not be created."
        mock_print.assert_any_call(expected_message)


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
    GET /session/topic_suggestions のテスト（インサイトなし）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="") # インサイトが空

    response = client.get(
        '/api/session/topic_suggestions',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    assert response.status_code == 200
    data = response.get_json()
    assert data['suggestions'] == []


# ===== /home/suggestion_v2 のテスト =====

def test_get_home_suggestion_v2_success(client, mocker):
    """
    GET /home/suggestion_v2 の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # Vector Searchの環境変数をモック
    mocker.patch('gateway.main.VECTOR_SEARCH_INDEX_ID', 'mock_index_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_ENDPOINT_ID', 'mock_endpoint_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_DEPLOYED_INDEX_ID', 'mock_deployed_id')
    mocker.patch('gateway.main.project_id', 'mock_project_id')
    mocker.patch('gateway.main.vector_search_region', 'mock_region')

    # --- 複雑なライブラリ呼び出しをモック ---
    # 1. Firestoreからのベクトル取得をモック
    mock_latest_vector_doc = MagicMock()
    mock_latest_vector_doc.id = 'my_own_vector_id'
    mock_latest_vector_doc.to_dict.return_value = {'embedding': [0.1, 0.2, 0.3]}
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream.return_value = [mock_latest_vector_doc]

    # 2. Vector Searchのfind_neighborsをモック
    mock_neighbor = MagicMock()
    mock_neighbor.id = 'similar_vector_id_123'
    mock_neighbors_response = [[mock_neighbor]] # find_neighborsはリストのリストを返す
    mock_index_endpoint_instance = MagicMock()
    mock_index_endpoint_instance.find_neighbors.return_value = mock_neighbors_response
    mocker.patch('gateway.main.aiplatform.MatchingEngineIndexEndpoint', return_value=mock_index_endpoint_instance)
    
    # 3. Vector Searchで見つかったIDに対応するドキュメント取得をモック
    mock_suggestion_doc = MagicMock()
    mock_suggestion_doc.exists = True
    mock_suggestion_doc.to_dict.return_value = {
        'nodeLabel': '提案されたノード',
        'nodeId': 'node_xyz'
    }
    # document()が特定のIDで呼ばれた時だけこのモックを返すように設定
    mock_db.collection.return_value.document.return_value.get.return_value = mock_suggestion_doc

    response = client.get('/api/home/suggestion_v2', headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'})

    assert response.status_code == 200
    data = response.get_json()
    assert data['nodeLabel'] == '提案されたノード'


def test_get_home_suggestion_v2_no_data(client, mocker):
    """
    GET /home/suggestion_v2 のテスト（データなし）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # Vector Searchの環境変数をモック
    mocker.patch('gateway.main.VECTOR_SEARCH_INDEX_ID', 'mock_index_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_ENDPOINT_ID', 'mock_endpoint_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_DEPLOYED_INDEX_ID', 'mock_deployed_id')
    mocker.patch('gateway.main.project_id', 'mock_project_id')
    mocker.patch('gateway.main.vector_search_region', 'mock_region')

    # ★★★ 修正: Firestoreからは常に空のリストが返るようにモック ★★★
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream.return_value = []

    response = client.get('/api/home/suggestion_v2', headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'})

    assert response.status_code == 204


def test_get_home_suggestion_v2_gemini_error(client, mocker):
    """
    GET /home/suggestion_v2 のテスト（Gemini呼び出し失敗）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # Vector Searchの環境変数をモック
    mocker.patch('gateway.main.VECTOR_SEARCH_INDEX_ID', 'mock_index_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_ENDPOINT_ID', 'mock_endpoint_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_DEPLOYED_INDEX_ID', 'mock_deployed_id')
    mocker.patch('gateway.main.project_id', 'mock_project_id')
    mocker.patch('gateway.main.vector_search_region', 'mock_region')

    # --- 複雑なライブラリ呼び出しをモック ---
    # 1. Firestoreからのベクトル取得をモック
    mock_latest_vector_doc = MagicMock()
    mock_latest_vector_doc.id = 'my_own_vector_id'
    mock_latest_vector_doc.to_dict.return_value = {'embedding': [0.1, 0.2, 0.3]}
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream.return_value = [mock_latest_vector_doc]

    # 2. Vector Searchのfind_neighborsをモック (今回は使われないが念のため)
    mock_neighbor = MagicMock()
    mock_neighbor.id = 'similar_vector_id_123'
    mock_neighbors_response = [[mock_neighbor]]
    mock_index_endpoint_instance = MagicMock()
    # ★★★ ここで例外を発生させる ★★★
    mock_index_endpoint_instance.find_neighbors.side_effect = Exception("Vector Search API Error")
    mocker.patch('gateway.main.aiplatform.MatchingEngineIndexEndpoint', return_value=mock_index_endpoint_instance)
    
    response = client.get('/api/home/suggestion_v2', headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'})

    assert response.status_code == 500
    data = response.get_json()
    assert "Failed to get home suggestion" in data['error']

def test_continue_session_success_with_prefetched_questions(client, mocker):
    """
    POST /session/<id>/continue の正常系テスト（プリフェッチされた質問を使用）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_generate_questions = mocker.patch('gateway.main.generate_follow_up_questions')

    # --- Firestoreのモック設定 ---
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_transaction = mock_db.transaction.return_value
    mock_batch = mock_db.batch.return_value

    # 1. トランザクション内のsession.get()をモック
    mock_session_snapshot = MagicMock(exists=True)
    mock_session_snapshot.to_dict.return_value = {'turn': 1} # 現在のターンは1

    # 2. プリフェッチされた質問のget()をモック
    mock_prefetched_doc = MagicMock(exists=True)
    mock_prefetched_doc.to_dict.return_value = {
        'questions': [{'question_text': 'プリフェッチされた質問ですか？'}]
    }
    mock_prefetched_ref = MagicMock()
    mock_prefetched_ref.get.return_value = mock_prefetched_doc

    # 3. セッション参照と、その中で呼ばれるメソッドをモック
    mock_session_ref = MagicMock()
    # トランザクション内で呼ばれるget
    mock_session_ref.get.return_value = mock_session_snapshot
    def collection_side_effect(name):
        if name == 'prefetched_questions':
            return MagicMock(document=lambda doc_id: mock_prefetched_ref)
        if name == 'questions':
             # 引数なしのdocument()呼び出しのために、IDを持つ新しいMagicMockを返す
            return MagicMock(document=lambda: MagicMock(id='new_q_id'))
        return MagicMock()
    mock_session_ref.collection.side_effect = collection_side_effect
    
    # 4. users/{uid}/sessions/{sid} のパスをモック
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref
    
    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )

    # --- アサーション ---
    assert response.status_code == 200
    data = response.get_json()
    assert data['turn'] == 2
    assert len(data['questions']) == 1
    assert data['questions'][0]['question_text'] == 'プリフェッチされた質問ですか？'
    # プリフェッチされたドキュメントが削除されたことを確認
    mock_prefetched_ref.delete.assert_called_once()
    # その場で質問が生成されていないことを確認
    mock_generate_questions.assert_not_called()
    # トランザクションとバッチがコミットされたことを確認
    mock_transaction.update.assert_called_once()
    mock_batch.commit.assert_called_once()
    

def test_continue_session_success_without_prefetched_questions(client, mocker):
    """
    POST /session/<id>/continue の正常系テスト（質問をその場で生成）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_generate_questions = mocker.patch(
        'gateway.main.generate_follow_up_questions', 
        return_value=[{'question_text': 'その場で生成された質問ですか？'}]
    )

    # --- Firestoreのモック設定 ---
    mock_db = mocker.patch('gateway.main.db_firestore')

    mock_session_snapshot = MagicMock(exists=True)
    mock_session_snapshot.to_dict.return_value = {'turn': 2}

    # プリフェッチは存在しない
    mock_prefetched_snapshot = MagicMock(exists=False)
    
    # 最新のサマリーのモック
    mock_summary_doc = MagicMock()
    mock_summary_doc.to_dict.return_value = {'insights': '最新のインサイト'}
    
    # collection().document()のモック
    mock_session_ref = MagicMock()
    mock_session_ref.get.return_value = mock_session_snapshot

    def collection_side_effect(name):
        if name == 'prefetched_questions':
            # プリフェッチドキュメントは存在しない
            return MagicMock(document=lambda doc_id: MagicMock(get=lambda: mock_prefetched_snapshot))
        if name == 'summaries':
             # サマリーは存在する
            return MagicMock(order_by=lambda key, direction: MagicMock(limit=lambda num: MagicMock(stream=lambda: [mock_summary_doc])))
        if name == 'questions':
            # questions.document()がIDを返すようにする
            return MagicMock(document=lambda: MagicMock(id='new_q_id'))
        return MagicMock()
        
    mock_session_ref.collection.side_effect = collection_side_effect
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref

    mocker.patch.object(mock_db, 'transaction')
    mock_batch = mocker.patch.object(mock_db, 'batch')

    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )
    
    # --- アサーション ---
    assert response.status_code == 200
    mock_generate_questions.assert_called_once_with('最新のインサイト')
    mock_batch.return_value.commit.assert_called_once()
    data = response.get_json()
    assert data['turn'] == 3
    assert data['questions'][0]['question_text'] == 'その場で生成された質問ですか？'


def test_continue_session_max_turns_reached(client, mocker):
    """
    POST /session/<id>/continue の異常系テスト（最大ターン超過）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_db = mocker.patch('gateway.main.db_firestore')
    
    # トランザクションが呼ばれることをモック
    mocker.patch.object(mock_db, 'transaction')
    
    # セッションのターンがMAX_TURNSに達しているようにモック
    mock_session_snapshot = MagicMock(exists=True)
    mocker.patch('gateway.main.MAX_TURNS', 5)
    mock_session_snapshot.to_dict.return_value = {'turn': 5} 
    
    mock_session_ref = MagicMock()
    mock_session_ref.get.return_value = mock_session_snapshot
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref

    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )
    
    # --- アサーション ---
    assert response.status_code == 400
    assert "Maximum turns reached" in response.get_json()['error']


def test_continue_session_not_found(client, mocker):
    """
    POST /session/<id>/continue の異常系テスト（セッションが存在しない）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_db = mocker.patch('gateway.main.db_firestore')

    # --- トランザクションの振る舞いをモック ---
    mock_session_snapshot = MagicMock(exists=False) # セッションが存在しない
    mock_session_ref = MagicMock()
    mock_session_ref.get.return_value = mock_session_snapshot
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref

    def run_transaction_side_effect(transaction_function, *args, **kwargs):
        transaction_mock = MagicMock()
        # Session not foundで例外が発生することをシミュレート
        with pytest.raises(Exception, match="Session not found"):
             transaction_function(transaction_mock, *args, **kwargs)
        # 例外が発生した後は、main.pyのexcept節に処理が移る
        # そのため、ここからの返り値はAPIレスポンスに直接は影響しない
        return None

    mock_transaction = mock_db.transaction.return_value
    mock_transaction.run.side_effect = run_transaction_side_effect
    
    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )
    
    assert response.status_code == 500
    # ★★★ 修正: 例外メッセージはレスポンスに含まれないため、アサーションを修正
    assert "Failed to continue session" in response.get_json()['error']

def test_app_check_valid_token(client, mocker):
    """
    正常なApp Checkトークンを持つリクエストが成功するかのテスト
    """
    # 実行環境をCloud Runに見せかける
    mocker.patch.dict('os.environ', {'K_SERVICE': 'test-service'})
    # App Checkの検証が成功するようにモック
    mocker.patch('gateway.main.app_check.verify_token', return_value={})

    # 実際のAPIリクエストを送信
    response = client.get('/api/', headers={'X-Firebase-AppCheck': 'valid_token'})
    
    # ステータスコードが200 OKであることを確認
    assert response.status_code == 200

def test_app_check_missing_token(client, mocker):
    """
    App Checkトークンがないリクエストが401エラーになるかのテスト
    """
    mocker.patch.dict('os.environ', {'K_SERVICE': 'test-service'})

    # ヘッダーにトークンを付けずにリクエストを送信
    response = client.get('/api/', headers={})
    
    # 401 Unauthorizedが返ってくることを確認
    assert response.status_code == 401
    # ★★★ レスポンスJSONのキーとメッセージを修正 ★★★
    assert response.get_json()['error'] == "App Check token is missing."

def test_app_check_invalid_token(client, mocker):
    """
    無効なApp Checkトークンを持つリクエストが401エラーになるかのテスト
    """
    mocker.patch.dict('os.environ', {'K_SERVICE': 'test-service'})
    # App Checkの検証が失敗(例外発生)するようにモック
    exception_message = "Test Token Exception"
    mocker.patch('gateway.main.app_check.verify_token', side_effect=Exception(exception_message))

    # 無効なトークンを付けてリクエストを送信
    response = client.get('/api/', headers={'X-Firebase-AppCheck': 'invalid_token'})

    # 401 Unauthorizedが返ってくることを確認
    assert response.status_code == 401
    # ★★★ レスポンスJSONのキーとメッセージを修正 ★★★
    assert response.get_json()['error'] == f"Invalid App Check token: {exception_message}"

def test_initialization_with_ollama(mocker):
    """
    Ollamaが設定されている場合に正常に初期化ログが出力されるかのテスト
    """
    mock_env = {
        'OLLAMA_ENDPOINT': 'http://localhost:11434',
        'OLLAMA_MODEL_NAME': 'test-model'
    }
    mocker.patch.dict('os.environ', mock_env)

    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        mock_print.assert_any_call("✅ Ollama service endpoint is configured: http://localhost:11434")
        mock_print.assert_any_call("✅ Ollama model name is set to: test-model")

def test_initialization_failure(mocker):
    """
    初期化中に予期せぬ例外が発生した場合のテスト
    """
    # Firebaseの初期化で意図的に例外を発生させる
    mocker.patch('firebase_admin.initialize_app', side_effect=ValueError("Test initialization failure"))
    mocker.patch('traceback.print_exc') # traceback.print_excをモック
    mocker.patch.dict('os.environ', {}, clear=True)

    with patch('gateway.main.print') as mock_print:
        # K_SERVICEがないローカル環境では例外がraiseされないことを確認
        import importlib
        importlib.reload(gateway.main)
        mock_print.assert_any_call("❌ Error during initialization: Test initialization failure")

        # K_SERVICEがある本番環境では例外がraiseされることを確認
        mocker.patch.dict('os.environ', {'K_SERVICE': 'true'})
        with pytest.raises(ValueError, match="Test initialization failure"):
             importlib.reload(gateway.main)


@pytest.fixture
def mock_generative_model(mocker):
    """GenerativeModelのモックを返すフィクスチャ"""
    mock_model_instance = MagicMock()
    # gateway.main.GenerativeModel をモックします
    mock_model_class = mocker.patch('gateway.main.GenerativeModel')
    # GenerativeModel("model-name") の呼び出しで、mock_model_instance を返すように設定します
    mock_model_class.return_value = mock_model_instance
    return mock_model_instance

def test_call_gemini_with_schema_success(mock_generative_model):
    """_call_gemini_with_schema: 正常系テスト"""
    mock_response = MagicMock()
    mock_response.text = '{"key": "value"}'
    mock_generative_model.generate_content.return_value = mock_response

    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")

    assert result == {"key": "value"}
    mock_generative_model.generate_content.assert_called_once()


def test_call_gemini_with_schema_strips_markdown(mock_generative_model):
    """_call_gemini_with_schema: 応答がMarkdownコードブロックで囲まれている場合に整形されるかのテスト"""
    mock_response = MagicMock()
    
    # ` ```json ... ``` ` パターン
    mock_response.text = '```json\n{"key": "value"}\n```'
    mock_generative_model.generate_content.return_value = mock_response
    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")
    assert result == {"key": "value"}
    mock_generative_model.generate_content.assert_called_once()
    mock_generative_model.generate_content.reset_mock()

    # ` ``` ... ``` ` パターン
    mock_response.text = '```\n{"key": "value"}\n```'
    mock_generative_model.generate_content.return_value = mock_response
    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")
    assert result == {"key": "value"}
    mock_generative_model.generate_content.assert_called_once()


def test_call_gemini_with_schema_retry_on_json_error(mock_generative_model, mocker):
    """_call_gemini_with_schema: 不正なJSONでリトライがかかるかのテスト"""
    mocker.patch('tenacity.nap.sleep') # リトライの待機時間をなくしてテストを高速化
    mocker.patch('traceback.print_exc') # 例外スタックトレースの出力を抑制

    # 1回目は不正なJSON、2回目は正しいJSONを返すように設定
    mock_response_invalid = MagicMock()
    mock_response_invalid.text = '{"key": "value"' # 不正なJSON
    mock_response_valid = MagicMock()
    mock_response_valid.text = '{"key": "value"}'

    mock_generative_model.generate_content.side_effect = [
        mock_response_invalid,
        mock_response_valid
    ]

    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")

    assert result == {"key": "value"}
    assert mock_generative_model.generate_content.call_count == 2, "JSONパースエラーにより、Geminiの呼び出しが2回行われるべき"


def test_call_gemini_with_schema_retry_on_api_error(mock_generative_model, mocker):
    """_call_gemini_with_schema: APIエラーでリトライがかかるかのテスト"""
    mocker.patch('tenacity.nap.sleep') # リトライの待機時間をなくしてテストを高速化
    mocker.patch('traceback.print_exc') # 例外スタックトレースの出力を抑制

    # 1回目は例外を発生させ、2回目は正しい応答を返すように設定
    mock_response_valid = MagicMock()
    mock_response_valid.text = '{"key": "value"}'

    mock_generative_model.generate_content.side_effect = [
        Exception("API Error"),
        mock_response_valid
    ]

    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")

    assert result == {"key": "value"}
    assert mock_generative_model.generate_content.call_count == 2, "APIエラーにより、Geminiの呼び出しが2回行われるべき"


def test_generate_initial_questions_for_new_user(mocker):
    """generate_initial_questions: 過去の対話履歴がない新規ユーザー向けのテスト"""
    # 依存する関数をモック
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="")
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"questions": ["新規ユーザー向けの質問"]})

    # 関数を呼び出し
    questions = gateway.main.generate_initial_questions("テストトピック", "new_user_id")

    # アサーション
    assert questions == ["新規ユーザー向けの質問"]
    gateway.main._get_all_insights_as_text.assert_called_once_with("new_user_id")
    
    # _call_gemini_with_schema に渡されたプロンプトを検証
    call_args = mock_call_gemini.call_args
    prompt = call_args[0][0] # 最初の位置引数（prompt）を取得
    assert "過去の対話の要約" not in prompt
    # ★★★ 修正: コード上のコメントではなく、プロンプトに実際に含まれるテキストを検証する ★★★
    assert "このテーマについて、ユーザーが深く内省できるような" in prompt

def test_generate_initial_questions_for_existing_user(mocker):
    """generate_initial_questions: 過去の対話履歴がある既存ユーザー向けのテスト"""
    # 依存する関数をモック
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="過去のインサイトです。")
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"questions": ["既存ユーザー向けの質問"]})

    # 関数を呼び出し
    questions = gateway.main.generate_initial_questions("テストトピック", "existing_user_id")

    # アサーション
    assert questions == ["既存ユーザー向けの質問"]
    gateway.main._get_all_insights_as_text.assert_called_once_with("existing_user_id")

    # _call_gemini_with_schema に渡されたプロンプトを検証
    call_args = mock_call_gemini.call_args
    prompt = call_args[0][0]
    assert "過去の対話の要約" in prompt
    assert "過去のインサイトです" in prompt
    assert "過去の対話がない新規ユーザー向けのフォールバック" not in prompt


def test_generate_follow_up_questions(mocker):
    """generate_follow_up_questions: 正常系のテスト"""
    # 依存する関数をモック
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"questions": ["フォローアップの質問です"]})
    
    # ダミーのインサイトデータ
    insights = "これが分析結果のテキストです。"

    # 関数を呼び出し
    questions = gateway.main.generate_follow_up_questions(insights)

    # アサーション
    assert questions == ["フォローアップの質問です"]
    
    # _call_gemini_with_schema が期待通りに呼ばれたか検証
    mock_call_gemini.assert_called_once()
    call_args = mock_call_gemini.call_args
    prompt = call_args[0][0]
    assert insights in prompt # プロンプトにインサイトが含まれていることを確認

def test_generate_summary_only(mocker):
    """generate_summary_only: 正常系のテスト"""
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"title": "test"})
    result = gateway.main.generate_summary_only("topic", "swipes")
    assert result == {"title": "test"}
    mock_call_gemini.assert_called_once()
    prompt = mock_call_gemini.call_args[0][0]
    assert "topic" in prompt
    assert "swipes" in prompt

def test_generate_graph_data(mocker):
    """generate_graph_data: 正常系のテスト"""
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"nodes": []})
    result = gateway.main.generate_graph_data("insights")
    assert result == {"nodes": []}
    mock_call_gemini.assert_called_once()
    prompt = mock_call_gemini.call_args[0][0]
    assert "insights" in prompt

def test_generate_chat_response(mock_generative_model):
    """generate_chat_response: RAGコンテキストなしのテスト"""
    mock_generative_model.generate_content.return_value.text = "AIの応答"
    result = gateway.main.generate_chat_response("summary", [], "user message")
    assert result == "AIの応答"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "参考情報" not in prompt
    assert "summary" in prompt
    assert "user message" in prompt

def test_generate_chat_response_with_rag(mock_generative_model):
    """generate_chat_response: RAGコンテキストありのテスト"""
    mock_generative_model.generate_content.return_value.text = "RAG応答"
    result = gateway.main.generate_chat_response("summary", [], "user message", rag_context="RAGコンテキスト")
    assert result == "RAG応答"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "参考情報" in prompt
    assert "RAGコンテキスト" in prompt

def test_generate_topic_suggestions(mocker):
    """generate_topic_suggestions: 正常系のテスト"""
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"suggestions": ["suggestion1"]})
    result = gateway.main.generate_topic_suggestions("insights")
    assert result == ["suggestion1"]
    mock_call_gemini.assert_called_once()
    prompt = mock_call_gemini.call_args[0][0]
    assert "insights" in prompt

def test_extract_keywords_for_search(mock_generative_model):
    """_extract_keywords_for_search: 正常系のテスト"""
    mock_generative_model.generate_content.return_value.text = "キーワード1, キーワード2"
    result = gateway.main._extract_keywords_for_search("analysis")
    assert result == "キーワード1, キーワード2"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "analysis" in prompt

def test_extract_keywords_for_search_failure(mock_generative_model):
    """_extract_keywords_for_search: Gemini呼び出しが失敗した場合のテスト"""
    mock_generative_model.generate_content.side_effect = Exception("API Error")
    result = gateway.main._extract_keywords_for_search("analysis")
    assert result == ""

def test_summarize_internal_context(mock_generative_model):
    """_summarize_internal_context: 正常系のテスト"""
    mock_generative_model.generate_content.return_value.text = "要約結果"
    result = gateway.main._summarize_internal_context("context", "keyword")
    assert result == "要約結果"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "context" in prompt
    assert "keyword" in prompt

def test_summarize_internal_context_failure(mock_generative_model):
    """_summarize_internal_context: Gemini呼び出しが失敗した場合のテスト"""
    mock_generative_model.generate_content.side_effect = Exception("API Error")
    result = gateway.main._summarize_internal_context("context", "keyword")
    assert result == "過去の記録を要約中にエラーが発生しました。"

def test_summarize_internal_context_no_input():
    """_summarize_internal_context: 入力がない場合に早期リターンするかのテスト"""
    result = gateway.main._summarize_internal_context("", "keyword")
    assert result == "このテーマについて、これまで具体的なお話はなかったようです。"
    result = gateway.main._summarize_internal_context("context", "")
    assert result == "このテーマについて、これまで具体的なお話はなかったようです。"


# --- RAG Helper Function Tests ---

@pytest.fixture
def mock_text_embedding_model(mocker):
    """TextEmbeddingModelのモックを返すフィクスチャ"""
    mock_model_instance = MagicMock()
    mock_model_class = mocker.patch('gateway.main.TextEmbeddingModel.from_pretrained')
    mock_model_class.return_value = mock_model_instance
    return mock_model_instance

def test_get_embeddings_success(mock_text_embedding_model):
    """_get_embeddings: 正常系のテスト"""
    # model.get_embeddings([{"text": t} for t in batch]) の形式を模倣
    mock_embedding = MagicMock()
    mock_embedding.values = [0.1, 0.2]
    mock_text_embedding_model.get_embeddings.return_value = [mock_embedding]

    embeddings = gateway.main._get_embeddings(["text1", "text2"])
    
    assert len(embeddings) == 1
    assert embeddings[0] == [0.1, 0.2]
    mock_text_embedding_model.get_embeddings.assert_called()

def test_get_embeddings_empty_input():
    """_get_embeddings: 入力が空リストの場合のテスト"""
    result = gateway.main._get_embeddings([])
    assert result == []

def test_get_embeddings_api_failure(mock_text_embedding_model, mocker):
    """_get_embeddings: APIエラーが発生した場合のテスト"""
    mocker.patch('tenacity.nap.sleep')
    mocker.patch('traceback.print_exc')
    mock_text_embedding_model.get_embeddings.side_effect = Exception("Embedding Error")
    
    # ★★★ 修正: RetryErrorが発生することを検証する ★★★
    with pytest.raises(tenacity.RetryError):
        gateway.main._get_embeddings(["text1"])
        
    # ★★★ 修正: stop_after_attempt(3) は合計3回試行する ★★★
    assert mock_text_embedding_model.get_embeddings.call_count == 3

def test_get_url_cache_doc_ref(mocker):
    """_get_url_cache_doc_ref: Firestoreのドキュメント参照を正しく構築するかのテスト"""
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_collection = mock_db.collection.return_value
    mock_doc = mock_collection.document.return_value
    
    url = "http://example.com"
    import hashlib
    url_hash = hashlib.sha256(url.encode('utf-8')).hexdigest()

    ref = gateway.main._get_url_cache_doc_ref(url)

    mock_db.collection.assert_called_once_with(gateway.main.RAG_CACHE_COLLECTION)
    mock_collection.document.assert_called_once_with(url_hash)
    assert ref == mock_doc

def test_get_cached_chunks_and_embeddings(mocker):
    """_get_cached_chunks_and_embeddings: キャッシュからデータを取得するテスト"""
    mock_doc_ref = MagicMock()
    mock_doc_snapshot = MagicMock()
    mock_doc_snapshot.exists = True
    # ★★★ 修正: フィールド名を'cached_at'に修正 ★★★
    mock_doc_snapshot.to_dict.return_value = {
        'chunks': ['chunk1'],
        'embeddings': [{'vector': [0.1]}],
        'cached_at': datetime.now(timezone.utc)
    }
    mock_doc_ref.get.return_value = mock_doc_snapshot
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)

    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks == ['chunk1']
    assert embeddings == [[0.1]]


def test_get_cached_chunks_and_embeddings_not_found(mocker):
    """_get_cached_chunks_and_embeddings: キャッシュが存在しない場合のテスト"""
    mock_doc_ref = MagicMock()
    mock_doc_snapshot = MagicMock()
    mock_doc_snapshot.exists = False
    mock_doc_ref.get.return_value = mock_doc_snapshot
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)

    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks is None
    assert embeddings is None

def test_set_cached_chunks_and_embeddings(mocker):
    """_set_cached_chunks_and_embeddings: キャッシュを設定するテスト"""
    mock_doc_ref = MagicMock()
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)
    mocker.patch('gateway.main.firestore.SERVER_TIMESTAMP', 'test_timestamp')

    gateway.main._set_cached_chunks_and_embeddings("http://example.com", ["chunk1"], [[0.1]])

    mock_doc_ref.set.assert_called_once()
    set_data = mock_doc_ref.set.call_args[0][0]
    assert set_data['chunks'] == ["chunk1"]
    assert set_data['embeddings'] == [{'vector': [0.1]}]
    # ★★★ 修正: フィールド名を'cached_at'に修正 ★★★
    assert 'cached_at' in set_data

def test_search_with_vertex_ai_search(mocker):
    """_search_with_vertex_ai_search: 正常系のテスト"""
    mock_search_response = MagicMock()
    mock_result = MagicMock()
    mock_result.document.derived_struct_data = {"link": "http://example.com"}
    mock_search_response.results = [mock_result]
    
    mock_search_client = mocker.patch('gateway.main.discoveryengine.SearchServiceClient').return_value
    mock_search_client.search.return_value = mock_search_response
    
    results = gateway.main._search_with_vertex_ai_search("proj", "loc", "engine", "query")
    
    assert results == ["http://example.com"]
    mock_search_client.search.assert_called_once()


def test_scrape_text_from_url_success(mocker):
    """_scrape_text_from_url: 正常系のテスト"""
    mock_response = mocker.patch('requests.get').return_value
    mock_response.status_code = 200
    mock_response.text = "<html><body><p>Hello World</p></body></html>"
    
    text = gateway.main._scrape_text_from_url("http://example.com")
    
    assert "Hello World" in text


def test_scrape_text_from_url_skipped_domain():
    """_scrape_text_from_url: スキップ対象ドメインのテスト"""
    text = gateway.main._scrape_text_from_url("https://x.com/some_path")
    assert text == ""

def test_scrape_text_from_url_request_fails(mocker):
    """_scrape_text_from_url: requests.getが失敗するテスト"""
    mocker.patch('requests.get', side_effect=requests.exceptions.RequestException("Error"))
    text = gateway.main._scrape_text_from_url("http://example.com")
    assert text == ""


def test_generate_rag_based_advice_no_keywords(mocker):
    """_generate_rag_based_advice: キーワードが抽出できなかった場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="")
    # この関数が呼ばれないようにモックしておく
    mocker.patch('gateway.main._search_with_vertex_ai_search')
    
    advice = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")
    
    # ★★★ 修正: 実際の返り値に合わせる ★★★
    assert advice == ('関連する外部情報を見つけることができませんでした。', [])


def test_generate_rag_based_advice_no_search_results(mocker):
    """_generate_rag_based_advice: 検索結果がなかった場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="キーワード")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=[])
    
    advice = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")
    
    # ★★★ 修正: 実際の返り値に合わせる ★★★
    assert advice == ('関連する外部情報を見つけることができませんでした。', [])


def test_generate_rag_based_advice_success_flow(mocker, mock_generative_model):
    """_generate_rag_based_advice: 正常系のメインフローをテスト"""
    # --- 依存関係のモックを設定 ---
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="キーワード")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://example.com/page1"])
    # 1. キャッシュは最初は見つからない
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(None, None))
    # 2. スクレイピングは成功する
    mocker.patch('gateway.main._scrape_text_from_url', return_value="スクレイピングしたテキスト")
    # 3. 埋め込みベクトルも生成される
    mock_get_embeddings = mocker.patch('gateway.main._get_embeddings', return_value=[[0.1, 0.2]])
    # 4. キャッシュへの保存もモック
    mock_set_cache = mocker.patch('gateway.main._set_cached_chunks_and_embeddings')
    # 5. 最終的なアドバイス生成モデル
    mock_generative_model.generate_content.return_value.text = "最終的なアドバイスです。"

    # --- 関数を呼び出し ---
    advice, sources = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")

    # --- アサーション ---
    assert advice == "最終的なアドバイスです。"
    assert sources == ["http://example.com/page1"]

    # --- 各モックが期待通りに呼ばれたか検証 ---
    gateway.main._get_cached_chunks_and_embeddings.assert_called()
    gateway.main._scrape_text_from_url.assert_called_once_with("http://example.com/page1")
    mock_get_embeddings.assert_called()
    mock_set_cache.assert_called()
    mock_generative_model.generate_content.assert_called_once()
    # プロンプトにスクレイピングしたテキストが含まれていることを確認
    final_prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "スクレイピングしたテキスト" in final_prompt

def test_generate_rag_based_advice_with_cache(mocker, mock_generative_model):
    """_generate_rag_based_advice: キャッシュがヒットした場合のフローをテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="キーワード")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://cached-example.com/page2"])
    # 1. キャッシュが見つかる
    cached_chunks = ["キャッシュされたテキスト"]
    cached_embeddings = [[0.3, 0.4]]
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(cached_chunks, cached_embeddings))
    
    # ★★★ 修正: クエリの埋め込みベクトル生成もモックする ★★★
    mock_get_embeddings = mocker.patch('gateway.main._get_embeddings', return_value=[[0.3, 0.4]])
    
    # スクレイピングが呼ばれないようにモック
    mock_scrape = mocker.patch('gateway.main._scrape_text_from_url')
    
    mock_generative_model.generate_content.return_value.text = "キャッシュを使ったアドバイス"

    advice, sources = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")

    assert advice == "キャッシュを使ったアドバイス"
    assert sources == ["http://cached-example.com/page2"]
    
    # キャッシュが使われたので、スクレイピングは呼ばれないはず
    mock_scrape.assert_not_called()
    # get_embeddingsはクエリの埋め込み取得で1回呼ばれる
    mock_get_embeddings.assert_called_once_with(["query"])

    # プロンプトにキャッシュされたテキストが含まれていることを確認
    final_prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "キャッシュされたテキスト" in final_prompt


def test_verify_token_invalid(app, mocker):
    """_verify_token: トークン検証に失敗した場合のテスト"""
    mocker.patch('gateway.main.auth.verify_id_token', side_effect=ValueError("Invalid token"))
    mock_request = MagicMock()
    mock_request.headers.get.return_value = "Bearer invalid_token"
    
    # ★★★ 修正: アプリケーションコンテキスト内で実行 ★★★
    with app.test_request_context():
        response, status_code = gateway.main._verify_token(mock_request)
        assert status_code == 500
        assert response.get_json() == {"error": "Could not verify token"}

def test_verify_token_no_header(app, mocker):
    """_verify_token: Authorizationヘッダーがない場合のテスト"""
    mock_request = MagicMock()
    mock_request.headers.get.return_value = None
    
    # ★★★ 修正: アプリケーションコンテキスト内で実行 ★★★
    with app.test_request_context():
        response, status_code = gateway.main._verify_token(mock_request)
        assert status_code == 401
        assert response.get_json() == {"error": "Authorization header is missing"}

def test_create_cloud_task_success(mocker):
    """_create_cloud_task: 正常系のテスト"""
    # tasks_clientと関連するプロパティをモック
    mock_tasks_client = MagicMock()
    mocker.patch('gateway.main.tasks_client', mock_tasks_client)
    mocker.patch('gateway.main.project_id', "test-proj")
    mocker.patch('gateway.main.GCP_TASK_QUEUE_LOCATION', "test-loc")
    mocker.patch('gateway.main.GCP_TASK_QUEUE', "test-queue")
    mocker.patch('gateway.main.SERVICE_URL', "http://service.url")
    mocker.patch('gateway.main.GCP_TASK_SA_EMAIL', "sa@email.com")

    gateway.main._create_cloud_task({"key": "value"}, "/target")

    mock_tasks_client.create_task.assert_called_once()
    # taskオブジェクトの中身を部分的に検証
    task_arg = mock_tasks_client.create_task.call_args[1]['task']
    assert task_arg['http_request']['url'] == "http://service.url/target"
    assert task_arg['http_request']['oidc_token']['service_account_email'] == "sa@email.com"


def test_create_cloud_task_disabled(mocker):
    """_create_cloud_task: Cloud Tasksが無効な場合のテスト"""
    mocker.patch('gateway.main.tasks_client', None) # tasks_clientをNoneに設定
    mock_print = mocker.patch('builtins.print')

    gateway.main._create_cloud_task({"key": "value"}, "/target")
    
    # ★★★ 修正: 実際のエラーメッセージに合わせる ★★★
    mock_print.assert_any_call("⚠️ Cloud Tasks is not configured. Skipping task creation.")


def test_create_cloud_task_failure(mocker):
    """_create_cloud_task: タスク作成がAPIエラーで失敗した場合のテスト"""
    mock_tasks_client = MagicMock()
    mock_tasks_client.create_task.side_effect = Exception("API Error")
    mocker.patch('gateway.main.tasks_client', mock_tasks_client)
    mocker.patch('gateway.main.project_id', "test-proj")
    mocker.patch('gateway.main.GCP_TASK_QUEUE_LOCATION', "test-loc")
    mocker.patch('gateway.main.GCP_TASK_QUEUE', "test-queue")
    mocker.patch('gateway.main.SERVICE_URL', "http://service.url")
    mocker.patch('gateway.main.GCP_TASK_SA_EMAIL', "sa@email.com")
    mock_print = mocker.patch('builtins.print')
    mocker.patch('traceback.print_exc') # tracebackの出力を抑制

    gateway.main._create_cloud_task({"key": "value"}, "/target")

    # ★★★ 修正: 実際のエラーメッセージに合わせる ★★★
    mock_print.assert_any_call("❌ Failed to create Cloud Task for /target: API Error")

import pytest
from gateway.main import app as flask_app
import gateway.main  # モックの呼び出し検証のために追加
import json
import copy
from unittest.mock import Mock, MagicMock, patch # ★★★ 修正: MagicMockを追加 ★★★
from datetime import datetime, timezone
import firebase_admin # ★★★ firebase_adminをインポート ★★★
import os # ★★★ osをインポート ★★★
import tenacity # ★★★ tenacityをインポート ★★★
import requests # ★★★ requestsをインポート ★★★

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

def cleanup_firebase_app():
    """既存のFirebaseアプリを削除するヘルパー関数"""
    if firebase_admin._apps:
        firebase_admin.delete_app(firebase_admin.get_app())

def test_cloud_tasks_initialization_success(mocker):
    """
    Cloud Tasksが正常に初期化されるかのテスト（環境変数が全て設定されている場合）
    """
    # ★★★ 既存のアプリをクリーンアップ ★★★
    cleanup_firebase_app()

    # 必要な環境変数をモック
    mock_env = {
        'K_SERVICE': 'test-service',
        'GCP_TASK_QUEUE': 'test-queue',
        'GCP_TASK_QUEUE_LOCATION': 'test-location',
        'GCP_TASK_SA_EMAIL': 'test-sa@example.com',
        'K_SERVICE_URL': 'https://test-service-url.com'
    }
    mocker.patch.dict('os.environ', mock_env)
    
    # CloudTasksClientのコンストラクタ自体をモック
    mock_tasks_client = mocker.patch('gateway.main.tasks_v2.CloudTasksClient')

    # mainモジュールを再読み込みして、トップレベルのコードを実行させる
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        
        # 初期化成功のログが出力されたことを確認
        mock_tasks_client.assert_called_once()
        mock_print.assert_any_call("✅ Cloud Tasks client initialized. Queue: test-queue in test-location")

def test_cloud_tasks_initialization_exception(mocker):
    """
    Cloud Tasksの初期化が例外を発生させた場合のテスト
    """
    cleanup_firebase_app()

    # 必要な環境変数はすべて設定
    mock_env = {
        'K_SERVICE': 'test-service',
        'GCP_TASK_QUEUE': 'test-queue',
        'GCP_TASK_QUEUE_LOCATION': 'test-location',
        'GCP_TASK_SA_EMAIL': 'test-sa@example.com',
        'K_SERVICE_URL': 'https://test-service-url.com'
    }
    mocker.patch.dict('os.environ', mock_env)
    
    # CloudTasksClientのコンストラクタが例外を投げるようにモック
    mocker.patch('gateway.main.tasks_v2.CloudTasksClient', side_effect=Exception("Test Exception"))
    mocker.patch('traceback.print_exc') # traceback.print_excもモックしておく

    # mainモジュールを再読み込み
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        
        # 初期化失敗のログが出力されたことを確認
        mock_print.assert_any_call("❌ Failed to initialize Cloud Tasks client, even though variables were set: Test Exception")

def test_google_books_api_key_loading_from_secret(mocker):
    """
    Google Books APIキーがSecret Managerから正常に読み込まれるかのテスト
    """
    cleanup_firebase_app()

    # os.path.existsとopenをモックする
    mocker.patch('os.path.exists', return_value=True)
    # openのモックは、read()メソッドを持つオブジェクトを返すように設定
    mocker.patch('builtins.open', mocker.mock_open(read_data='test_api_key_from_secret'))

    # mainモジュールを再読み込みして初期化コードを実行
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)

        # グローバル変数にキーが設定されたかを確認
        assert gateway.main.GOOGLE_BOOKS_API_KEY == 'test_api_key_from_secret'
        mock_print.assert_any_call("✅ Loaded Google Books API key from Secret Manager.")


def test_cloud_tasks_initialization_missing_vars(mocker):
    """
    Cloud Tasksが無効になるかのテスト（環境変数が不足している場合）
    """
    # ★★★ 既存のアプリをクリーンアップ ★★★
    cleanup_firebase_app()

    # 一部の環境変数だけをモック
    mock_env = {
        'K_SERVICE': 'test-service',
        'GCP_TASK_QUEUE': 'test-queue',
        # 他の変数は設定しない
    }
    mocker.patch.dict('os.environ', mock_env)
    
    # mainモジュールを再読み込み
    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        
        # 初期化が無効になった旨の警告ログが出力されたことを確認
        # ★★★ 修正: 出力されるメッセージを実際のコードと完全に一致させる ★★★
        expected_message = "⚠️ Cloud Tasks is disabled. Missing environment variables: GCP_TASK_QUEUE_LOCATION, GCP_TASK_SA_EMAIL, K_SERVICE_URL. Background tasks will not be created."
        mock_print.assert_any_call(expected_message)


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
    GET /session/topic_suggestions のテスト（インサイトなし）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="") # インサイトが空

    response = client.get(
        '/api/session/topic_suggestions',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'}
    )

    assert response.status_code == 200
    data = response.get_json()
    assert data['suggestions'] == []


# ===== /home/suggestion_v2 のテスト =====

def test_get_home_suggestion_v2_success(client, mocker):
    """
    GET /home/suggestion_v2 の正常系テスト
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # Vector Searchの環境変数をモック
    mocker.patch('gateway.main.VECTOR_SEARCH_INDEX_ID', 'mock_index_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_ENDPOINT_ID', 'mock_endpoint_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_DEPLOYED_INDEX_ID', 'mock_deployed_id')
    mocker.patch('gateway.main.project_id', 'mock_project_id')
    mocker.patch('gateway.main.vector_search_region', 'mock_region')

    # --- 複雑なライブラリ呼び出しをモック ---
    # 1. Firestoreからのベクトル取得をモック
    mock_latest_vector_doc = MagicMock()
    mock_latest_vector_doc.id = 'my_own_vector_id'
    mock_latest_vector_doc.to_dict.return_value = {'embedding': [0.1, 0.2, 0.3]}
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream.return_value = [mock_latest_vector_doc]

    # 2. Vector Searchのfind_neighborsをモック
    mock_neighbor = MagicMock()
    mock_neighbor.id = 'similar_vector_id_123'
    mock_neighbors_response = [[mock_neighbor]] # find_neighborsはリストのリストを返す
    mock_index_endpoint_instance = MagicMock()
    mock_index_endpoint_instance.find_neighbors.return_value = mock_neighbors_response
    mocker.patch('gateway.main.aiplatform.MatchingEngineIndexEndpoint', return_value=mock_index_endpoint_instance)
    
    # 3. Vector Searchで見つかったIDに対応するドキュメント取得をモック
    mock_suggestion_doc = MagicMock()
    mock_suggestion_doc.exists = True
    mock_suggestion_doc.to_dict.return_value = {
        'nodeLabel': '提案されたノード',
        'nodeId': 'node_xyz'
    }
    # document()が特定のIDで呼ばれた時だけこのモックを返すように設定
    mock_db.collection.return_value.document.return_value.get.return_value = mock_suggestion_doc

    response = client.get('/api/home/suggestion_v2', headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'})

    assert response.status_code == 200
    data = response.get_json()
    assert data['nodeLabel'] == '提案されたノード'


def test_get_home_suggestion_v2_no_data(client, mocker):
    """
    GET /home/suggestion_v2 のテスト（データなし）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # Vector Searchの環境変数をモック
    mocker.patch('gateway.main.VECTOR_SEARCH_INDEX_ID', 'mock_index_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_ENDPOINT_ID', 'mock_endpoint_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_DEPLOYED_INDEX_ID', 'mock_deployed_id')
    mocker.patch('gateway.main.project_id', 'mock_project_id')
    mocker.patch('gateway.main.vector_search_region', 'mock_region')

    # ★★★ 修正: Firestoreからは常に空のリストが返るようにモック ★★★
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream.return_value = []

    response = client.get('/api/home/suggestion_v2', headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'})

    assert response.status_code == 204


def test_get_home_suggestion_v2_gemini_error(client, mocker):
    """
    GET /home/suggestion_v2 のテスト（Gemini呼び出し失敗）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})

    # Vector Searchの環境変数をモック
    mocker.patch('gateway.main.VECTOR_SEARCH_INDEX_ID', 'mock_index_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_ENDPOINT_ID', 'mock_endpoint_id')
    mocker.patch('gateway.main.VECTOR_SEARCH_DEPLOYED_INDEX_ID', 'mock_deployed_id')
    mocker.patch('gateway.main.project_id', 'mock_project_id')
    mocker.patch('gateway.main.vector_search_region', 'mock_region')

    # --- 複雑なライブラリ呼び出しをモック ---
    # 1. Firestoreからのベクトル取得をモック
    mock_latest_vector_doc = MagicMock()
    mock_latest_vector_doc.id = 'my_own_vector_id'
    mock_latest_vector_doc.to_dict.return_value = {'embedding': [0.1, 0.2, 0.3]}
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_db.collection.return_value.where.return_value.order_by.return_value.limit.return_value.stream.return_value = [mock_latest_vector_doc]

    # 2. Vector Searchのfind_neighborsをモック (今回は使われないが念のため)
    mock_neighbor = MagicMock()
    mock_neighbor.id = 'similar_vector_id_123'
    mock_neighbors_response = [[mock_neighbor]]
    mock_index_endpoint_instance = MagicMock()
    # ★★★ ここで例外を発生させる ★★★
    mock_index_endpoint_instance.find_neighbors.side_effect = Exception("Vector Search API Error")
    mocker.patch('gateway.main.aiplatform.MatchingEngineIndexEndpoint', return_value=mock_index_endpoint_instance)
    
    response = client.get('/api/home/suggestion_v2', headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'})

    assert response.status_code == 500
    data = response.get_json()
    assert "Failed to get home suggestion" in data['error']

def test_continue_session_success_with_prefetched_questions(client, mocker):
    """
    POST /session/<id>/continue の正常系テスト（プリフェッチされた質問を使用）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_generate_questions = mocker.patch('gateway.main.generate_follow_up_questions')

    # --- Firestoreのモック設定 ---
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_transaction = mock_db.transaction.return_value
    mock_batch = mock_db.batch.return_value

    # 1. トランザクション内のsession.get()をモック
    mock_session_snapshot = MagicMock(exists=True)
    mock_session_snapshot.to_dict.return_value = {'turn': 1} # 現在のターンは1

    # 2. プリフェッチされた質問のget()をモック
    mock_prefetched_doc = MagicMock(exists=True)
    mock_prefetched_doc.to_dict.return_value = {
        'questions': [{'question_text': 'プリフェッチされた質問ですか？'}]
    }
    mock_prefetched_ref = MagicMock()
    mock_prefetched_ref.get.return_value = mock_prefetched_doc

    # 3. セッション参照と、その中で呼ばれるメソッドをモック
    mock_session_ref = MagicMock()
    # トランザクション内で呼ばれるget
    mock_session_ref.get.return_value = mock_session_snapshot
    def collection_side_effect(name):
        if name == 'prefetched_questions':
            return MagicMock(document=lambda doc_id: mock_prefetched_ref)
        if name == 'questions':
             # 引数なしのdocument()呼び出しのために、IDを持つ新しいMagicMockを返す
            return MagicMock(document=lambda: MagicMock(id='new_q_id'))
        return MagicMock()
    mock_session_ref.collection.side_effect = collection_side_effect
    
    # 4. users/{uid}/sessions/{sid} のパスをモック
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref
    
    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )

    # --- アサーション ---
    assert response.status_code == 200
    data = response.get_json()
    assert data['turn'] == 2
    assert len(data['questions']) == 1
    assert data['questions'][0]['question_text'] == 'プリフェッチされた質問ですか？'
    # プリフェッチされたドキュメントが削除されたことを確認
    mock_prefetched_ref.delete.assert_called_once()
    # その場で質問が生成されていないことを確認
    mock_generate_questions.assert_not_called()
    # トランザクションとバッチがコミットされたことを確認
    mock_transaction.update.assert_called_once()
    mock_batch.commit.assert_called_once()
    

def test_continue_session_success_without_prefetched_questions(client, mocker):
    """
    POST /session/<id>/continue の正常系テスト（質問をその場で生成）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_generate_questions = mocker.patch(
        'gateway.main.generate_follow_up_questions', 
        return_value=[{'question_text': 'その場で生成された質問ですか？'}]
    )

    # --- Firestoreのモック設定 ---
    mock_db = mocker.patch('gateway.main.db_firestore')

    mock_session_snapshot = MagicMock(exists=True)
    mock_session_snapshot.to_dict.return_value = {'turn': 2}

    # プリフェッチは存在しない
    mock_prefetched_snapshot = MagicMock(exists=False)
    
    # 最新のサマリーのモック
    mock_summary_doc = MagicMock()
    mock_summary_doc.to_dict.return_value = {'insights': '最新のインサイト'}
    
    # collection().document()のモック
    mock_session_ref = MagicMock()
    mock_session_ref.get.return_value = mock_session_snapshot

    def collection_side_effect(name):
        if name == 'prefetched_questions':
            # プリフェッチドキュメントは存在しない
            return MagicMock(document=lambda doc_id: MagicMock(get=lambda: mock_prefetched_snapshot))
        if name == 'summaries':
             # サマリーは存在する
            return MagicMock(order_by=lambda key, direction: MagicMock(limit=lambda num: MagicMock(stream=lambda: [mock_summary_doc])))
        if name == 'questions':
            # questions.document()がIDを返すようにする
            return MagicMock(document=lambda: MagicMock(id='new_q_id'))
        return MagicMock()
        
    mock_session_ref.collection.side_effect = collection_side_effect
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref

    mocker.patch.object(mock_db, 'transaction')
    mock_batch = mocker.patch.object(mock_db, 'batch')

    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )
    
    # --- アサーション ---
    assert response.status_code == 200
    mock_generate_questions.assert_called_once_with('最新のインサイト')
    mock_batch.return_value.commit.assert_called_once()
    data = response.get_json()
    assert data['turn'] == 3
    assert data['questions'][0]['question_text'] == 'その場で生成された質問ですか？'


def test_continue_session_max_turns_reached(client, mocker):
    """
    POST /session/<id>/continue の異常系テスト（最大ターン超過）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_db = mocker.patch('gateway.main.db_firestore')
    
    # トランザクションが呼ばれることをモック
    mocker.patch.object(mock_db, 'transaction')
    
    # セッションのターンがMAX_TURNSに達しているようにモック
    mock_session_snapshot = MagicMock(exists=True)
    mocker.patch('gateway.main.MAX_TURNS', 5)
    mock_session_snapshot.to_dict.return_value = {'turn': 5} 
    
    mock_session_ref = MagicMock()
    mock_session_ref.get.return_value = mock_session_snapshot
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref

    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )
    
    # --- アサーション ---
    assert response.status_code == 400
    assert "Maximum turns reached" in response.get_json()['error']


def test_continue_session_not_found(client, mocker):
    """
    POST /session/<id>/continue の異常系テスト（セッションが存在しない）
    """
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mock_db = mocker.patch('gateway.main.db_firestore')

    # --- トランザクションの振る舞いをモック ---
    mock_session_snapshot = MagicMock(exists=False) # セッションが存在しない
    mock_session_ref = MagicMock()
    mock_session_ref.get.return_value = mock_session_snapshot
    mock_db.collection.return_value.document.return_value.collection.return_value.document.return_value = mock_session_ref

    def run_transaction_side_effect(transaction_function, *args, **kwargs):
        transaction_mock = MagicMock()
        # Session not foundで例外が発生することをシミュレート
        with pytest.raises(Exception, match="Session not found"):
             transaction_function(transaction_mock, *args, **kwargs)
        # 例外が発生した後は、main.pyのexcept節に処理が移る
        # そのため、ここからの返り値はAPIレスポンスに直接は影響しない
        return None

    mock_transaction = mock_db.transaction.return_value
    mock_transaction.run.side_effect = run_transaction_side_effect
    
    # --- API呼び出し ---
    response = client.post(
        f'/api/session/{MOCK_SESSION_ID}/continue',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        content_type='application/json'
    )
    
    assert response.status_code == 500
    # ★★★ 修正: 例外メッセージはレスポンスに含まれないため、アサーションを修正
    assert "Failed to continue session" in response.get_json()['error']

def test_app_check_valid_token(client, mocker):
    """
    正常なApp Checkトークンを持つリクエストが成功するかのテスト
    """
    # 実行環境をCloud Runに見せかける
    mocker.patch.dict('os.environ', {'K_SERVICE': 'test-service'})
    # App Checkの検証が成功するようにモック
    mocker.patch('gateway.main.app_check.verify_token', return_value={})

    # 実際のAPIリクエストを送信
    response = client.get('/api/', headers={'X-Firebase-AppCheck': 'valid_token'})
    
    # ステータスコードが200 OKであることを確認
    assert response.status_code == 200

def test_app_check_missing_token(client, mocker):
    """
    App Checkトークンがないリクエストが401エラーになるかのテスト
    """
    mocker.patch.dict('os.environ', {'K_SERVICE': 'test-service'})

    # ヘッダーにトークンを付けずにリクエストを送信
    response = client.get('/api/', headers={})
    
    # 401 Unauthorizedが返ってくることを確認
    assert response.status_code == 401
    # ★★★ レスポンスJSONのキーとメッセージを修正 ★★★
    assert response.get_json()['error'] == "App Check token is missing."

def test_app_check_invalid_token(client, mocker):
    """
    無効なApp Checkトークンを持つリクエストが401エラーになるかのテスト
    """
    mocker.patch.dict('os.environ', {'K_SERVICE': 'test-service'})
    # App Checkの検証が失敗(例外発生)するようにモック
    exception_message = "Test Token Exception"
    mocker.patch('gateway.main.app_check.verify_token', side_effect=Exception(exception_message))

    # 無効なトークンを付けてリクエストを送信
    response = client.get('/api/', headers={'X-Firebase-AppCheck': 'invalid_token'})

    # 401 Unauthorizedが返ってくることを確認
    assert response.status_code == 401
    # ★★★ レスポンスJSONのキーとメッセージを修正 ★★★
    assert response.get_json()['error'] == f"Invalid App Check token: {exception_message}"

def test_initialization_with_ollama(mocker):
    """
    Ollamaが設定されている場合に正常に初期化ログが出力されるかのテスト
    """
    cleanup_firebase_app()
    mock_env = {
        'OLLAMA_ENDPOINT': 'http://localhost:11434',
        'OLLAMA_MODEL_NAME': 'test-model'
    }
    mocker.patch.dict('os.environ', mock_env)

    with patch('gateway.main.print') as mock_print:
        import importlib
        importlib.reload(gateway.main)
        mock_print.assert_any_call("✅ Ollama service endpoint is configured: http://localhost:11434")
        mock_print.assert_any_call("✅ Ollama model name is set to: test-model")

def test_initialization_failure(mocker):
    """
    初期化中に予期せぬ例外が発生した場合のテスト
    """
    cleanup_firebase_app()
    # Firebaseの初期化で意図的に例外を発生させる
    mocker.patch('firebase_admin.initialize_app', side_effect=ValueError("Test initialization failure"))
    mocker.patch('traceback.print_exc') # traceback.print_excをモック
    mocker.patch.dict('os.environ', {}, clear=True)

    with patch('gateway.main.print') as mock_print:
        # K_SERVICEがないローカル環境では例外がraiseされないことを確認
        import importlib
        importlib.reload(gateway.main)
        mock_print.assert_any_call("❌ Error during initialization: Test initialization failure")

        # K_SERVICEがある本番環境では例外がraiseされることを確認
        mocker.patch.dict('os.environ', {'K_SERVICE': 'true'})
        with pytest.raises(ValueError, match="Test initialization failure"):
             importlib.reload(gateway.main)


@pytest.fixture
def mock_generative_model(mocker):
    """GenerativeModelのモックを返すフィクスチャ"""
    mock_model_instance = MagicMock()
    # gateway.main.GenerativeModel をモックします
    mock_model_class = mocker.patch('gateway.main.GenerativeModel')
    # GenerativeModel("model-name") の呼び出しで、mock_model_instance を返すように設定します
    mock_model_class.return_value = mock_model_instance
    return mock_model_instance

def test_call_gemini_with_schema_success(mock_generative_model):
    """_call_gemini_with_schema: 正常系テスト"""
    mock_response = MagicMock()
    mock_response.text = '{"key": "value"}'
    mock_generative_model.generate_content.return_value = mock_response

    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")

    assert result == {"key": "value"}
    mock_generative_model.generate_content.assert_called_once()


def test_call_gemini_with_schema_strips_markdown(mock_generative_model):
    """_call_gemini_with_schema: 応答がMarkdownコードブロックで囲まれている場合に整形されるかのテスト"""
    mock_response = MagicMock()
    
    # ` ```json ... ``` ` パターン
    mock_response.text = '```json\n{"key": "value"}\n```'
    mock_generative_model.generate_content.return_value = mock_response
    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")
    assert result == {"key": "value"}
    mock_generative_model.generate_content.assert_called_once()
    mock_generative_model.generate_content.reset_mock()

    # ` ``` ... ``` ` パターン
    mock_response.text = '```\n{"key": "value"}\n```'
    mock_generative_model.generate_content.return_value = mock_response
    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")
    assert result == {"key": "value"}
    mock_generative_model.generate_content.assert_called_once()


def test_call_gemini_with_schema_retry_on_json_error(mock_generative_model, mocker):
    """_call_gemini_with_schema: 不正なJSONでリトライがかかるかのテスト"""
    mocker.patch('tenacity.nap.sleep') # リトライの待機時間をなくしてテストを高速化
    mocker.patch('traceback.print_exc') # 例外スタックトレースの出力を抑制

    # 1回目は不正なJSON、2回目は正しいJSONを返すように設定
    mock_response_invalid = MagicMock()
    mock_response_invalid.text = '{"key": "value"' # 不正なJSON
    mock_response_valid = MagicMock()
    mock_response_valid.text = '{"key": "value"}'

    mock_generative_model.generate_content.side_effect = [
        mock_response_invalid,
        mock_response_valid
    ]

    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")

    assert result == {"key": "value"}
    assert mock_generative_model.generate_content.call_count == 2, "JSONパースエラーにより、Geminiの呼び出しが2回行われるべき"


def test_call_gemini_with_schema_retry_on_api_error(mock_generative_model, mocker):
    """_call_gemini_with_schema: APIエラーでリトライがかかるかのテスト"""
    mocker.patch('tenacity.nap.sleep') # リトライの待機時間をなくしてテストを高速化
    mocker.patch('traceback.print_exc') # 例外スタックトレースの出力を抑制

    # 1回目は例外を発生させ、2回目は正しい応答を返すように設定
    mock_response_valid = MagicMock()
    mock_response_valid.text = '{"key": "value"}'

    mock_generative_model.generate_content.side_effect = [
        Exception("API Error"),
        mock_response_valid
    ]

    result = gateway.main._call_gemini_with_schema("test prompt", {}, "test-model")

    assert result == {"key": "value"}
    assert mock_generative_model.generate_content.call_count == 2, "APIエラーにより、Geminiの呼び出しが2回行われるべき"


def test_generate_initial_questions_for_new_user(mocker):
    """generate_initial_questions: 過去の対話履歴がない新規ユーザー向けのテスト"""
    # 依存する関数をモック
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="")
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"questions": ["新規ユーザー向けの質問"]})

    # 関数を呼び出し
    questions = gateway.main.generate_initial_questions("テストトピック", "new_user_id")

    # アサーション
    assert questions == ["新規ユーザー向けの質問"]
    gateway.main._get_all_insights_as_text.assert_called_once_with("new_user_id")
    
    # _call_gemini_with_schema に渡されたプロンプトを検証
    call_args = mock_call_gemini.call_args
    prompt = call_args[0][0] # 最初の位置引数（prompt）を取得
    assert "過去の対話の要約" not in prompt
    # ★★★ 修正: コード上のコメントではなく、プロンプトに実際に含まれるテキストを検証する ★★★
    assert "このテーマについて、ユーザーが深く内省できるような" in prompt

def test_generate_initial_questions_for_existing_user(mocker):
    """generate_initial_questions: 過去の対話履歴がある既存ユーザー向けのテスト"""
    # 依存する関数をモック
    mocker.patch('gateway.main._get_all_insights_as_text', return_value="過去のインサイトです。")
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"questions": ["既存ユーザー向けの質問"]})

    # 関数を呼び出し
    questions = gateway.main.generate_initial_questions("テストトピック", "existing_user_id")

    # アサーション
    assert questions == ["既存ユーザー向けの質問"]
    gateway.main._get_all_insights_as_text.assert_called_once_with("existing_user_id")

    # _call_gemini_with_schema に渡されたプロンプトを検証
    call_args = mock_call_gemini.call_args
    prompt = call_args[0][0]
    assert "過去の対話の要約" in prompt
    assert "過去のインサイトです" in prompt
    assert "過去の対話がない新規ユーザー向けのフォールバック" not in prompt


def test_generate_follow_up_questions(mocker):
    """generate_follow_up_questions: 正常系のテスト"""
    # 依存する関数をモック
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"questions": ["フォローアップの質問です"]})
    
    # ダミーのインサイトデータ
    insights = "これが分析結果のテキストです。"

    # 関数を呼び出し
    questions = gateway.main.generate_follow_up_questions(insights)

    # アサーション
    assert questions == ["フォローアップの質問です"]
    
    # _call_gemini_with_schema が期待通りに呼ばれたか検証
    mock_call_gemini.assert_called_once()
    call_args = mock_call_gemini.call_args
    prompt = call_args[0][0]
    assert insights in prompt # プロンプトにインサイトが含まれていることを確認

def test_generate_summary_only(mocker):
    """generate_summary_only: 正常系のテスト"""
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"title": "test"})
    result = gateway.main.generate_summary_only("topic", "swipes")
    assert result == {"title": "test"}
    mock_call_gemini.assert_called_once()
    prompt = mock_call_gemini.call_args[0][0]
    assert "topic" in prompt
    assert "swipes" in prompt

def test_generate_graph_data(mocker):
    """generate_graph_data: 正常系のテスト"""
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"nodes": []})
    result = gateway.main.generate_graph_data("insights")
    assert result == {"nodes": []}
    mock_call_gemini.assert_called_once()
    prompt = mock_call_gemini.call_args[0][0]
    assert "insights" in prompt

def test_generate_chat_response(mock_generative_model):
    """generate_chat_response: RAGコンテキストなしのテスト"""
    mock_generative_model.generate_content.return_value.text = "AIの応答"
    result = gateway.main.generate_chat_response("summary", [], "user message")
    assert result == "AIの応答"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "参考情報" not in prompt
    assert "summary" in prompt
    assert "user message" in prompt

def test_generate_chat_response_with_rag(mock_generative_model):
    """generate_chat_response: RAGコンテキストありのテスト"""
    mock_generative_model.generate_content.return_value.text = "RAG応答"
    result = gateway.main.generate_chat_response("summary", [], "user message", rag_context="RAGコンテキスト")
    assert result == "RAG応答"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "参考情報" in prompt
    assert "RAGコンテキスト" in prompt

def test_generate_topic_suggestions(mocker):
    """generate_topic_suggestions: 正常系のテスト"""
    mock_call_gemini = mocker.patch('gateway.main._call_gemini_with_schema', return_value={"suggestions": ["suggestion1"]})
    result = gateway.main.generate_topic_suggestions("insights")
    assert result == ["suggestion1"]
    mock_call_gemini.assert_called_once()
    prompt = mock_call_gemini.call_args[0][0]
    assert "insights" in prompt

def test_extract_keywords_for_search(mock_generative_model):
    """_extract_keywords_for_search: 正常系のテスト"""
    mock_generative_model.generate_content.return_value.text = "キーワード1, キーワード2"
    result = gateway.main._extract_keywords_for_search("analysis")
    assert result == "キーワード1, キーワード2"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "analysis" in prompt

def test_extract_keywords_for_search_failure(mock_generative_model):
    """_extract_keywords_for_search: Gemini呼び出しが失敗した場合のテスト"""
    mock_generative_model.generate_content.side_effect = Exception("API Error")
    result = gateway.main._extract_keywords_for_search("analysis")
    assert result == ""

def test_summarize_internal_context(mock_generative_model):
    """_summarize_internal_context: 正常系のテスト"""
    mock_generative_model.generate_content.return_value.text = "要約結果"
    result = gateway.main._summarize_internal_context("context", "keyword")
    assert result == "要約結果"
    prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "context" in prompt
    assert "keyword" in prompt

def test_summarize_internal_context_failure(mock_generative_model):
    """_summarize_internal_context: Gemini呼び出しが失敗した場合のテスト"""
    mock_generative_model.generate_content.side_effect = Exception("API Error")
    result = gateway.main._summarize_internal_context("context", "keyword")
    assert result == "過去の記録を要約中にエラーが発生しました。"

def test_summarize_internal_context_no_input():
    """_summarize_internal_context: 入力がない場合に早期リターンするかのテスト"""
    result = gateway.main._summarize_internal_context("", "keyword")
    assert result == "このテーマについて、これまで具体的なお話はなかったようです。"
    result = gateway.main._summarize_internal_context("context", "")
    assert result == "このテーマについて、これまで具体的なお話はなかったようです。"


# --- RAG Helper Function Tests ---

@pytest.fixture
def mock_text_embedding_model(mocker):
    """TextEmbeddingModelのモックを返すフィクスチャ"""
    mock_model_instance = MagicMock()
    mock_model_class = mocker.patch('gateway.main.TextEmbeddingModel.from_pretrained')
    mock_model_class.return_value = mock_model_instance
    return mock_model_instance

def test_get_embeddings_success(mock_text_embedding_model):
    """_get_embeddings: 正常系のテスト"""
    # model.get_embeddings([{"text": t} for t in batch]) の形式を模倣
    mock_embedding = MagicMock()
    mock_embedding.values = [0.1, 0.2]
    mock_text_embedding_model.get_embeddings.return_value = [mock_embedding]

    embeddings = gateway.main._get_embeddings(["text1", "text2"])
    
    assert len(embeddings) == 1
    assert embeddings[0] == [0.1, 0.2]
    mock_text_embedding_model.get_embeddings.assert_called()

def test_get_embeddings_empty_input():
    """_get_embeddings: 入力が空リストの場合のテスト"""
    result = gateway.main._get_embeddings([])
    assert result == []

def test_get_embeddings_api_failure(mock_text_embedding_model, mocker):
    """_get_embeddings: APIエラーが発生した場合のテスト"""
    mocker.patch('tenacity.nap.sleep')
    mocker.patch('traceback.print_exc')
    mock_text_embedding_model.get_embeddings.side_effect = Exception("Embedding Error")
    
    # ★★★ 修正: RetryErrorが発生することを検証する ★★★
    with pytest.raises(tenacity.RetryError):
        gateway.main._get_embeddings(["text1"])
        
    # ★★★ 修正: stop_after_attempt(3) は合計3回試行する ★★★
    assert mock_text_embedding_model.get_embeddings.call_count == 3

def test_get_url_cache_doc_ref(mocker):
    """_get_url_cache_doc_ref: Firestoreのドキュメント参照を正しく構築するかのテスト"""
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_collection = mock_db.collection.return_value
    mock_doc = mock_collection.document.return_value
    
    url = "http://example.com"
    import hashlib
    url_hash = hashlib.sha256(url.encode('utf-8')).hexdigest()

    ref = gateway.main._get_url_cache_doc_ref(url)

    mock_db.collection.assert_called_once_with(gateway.main.RAG_CACHE_COLLECTION)
    mock_collection.document.assert_called_once_with(url_hash)
    assert ref == mock_doc

def test_get_cached_chunks_and_embeddings(mocker):
    """_get_cached_chunks_and_embeddings: キャッシュからデータを取得するテスト"""
    mock_doc_ref = MagicMock()
    mock_doc_snapshot = MagicMock()
    mock_doc_snapshot.exists = True
    # ★★★ 修正: フィールド名を'cached_at'に修正 ★★★
    mock_doc_snapshot.to_dict.return_value = {
        'chunks': ['chunk1'],
        'embeddings': [{'vector': [0.1]}],
        'cached_at': datetime.now(timezone.utc)
    }
    mock_doc_ref.get.return_value = mock_doc_snapshot
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)

    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks == ['chunk1']
    assert embeddings == [[0.1]]


def test_get_cached_chunks_and_embeddings_not_found(mocker):
    """_get_cached_chunks_and_embeddings: キャッシュが存在しない場合のテスト"""
    mock_doc_ref = MagicMock()
    mock_doc_snapshot = MagicMock()
    mock_doc_snapshot.exists = False
    mock_doc_ref.get.return_value = mock_doc_snapshot
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)

    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks is None
    assert embeddings is None

def test_set_cached_chunks_and_embeddings(mocker):
    """_set_cached_chunks_and_embeddings: キャッシュを設定するテスト"""
    mock_doc_ref = MagicMock()
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)
    mocker.patch('gateway.main.firestore.SERVER_TIMESTAMP', 'test_timestamp')

    gateway.main._set_cached_chunks_and_embeddings("http://example.com", ["chunk1"], [[0.1]])

    mock_doc_ref.set.assert_called_once()
    set_data = mock_doc_ref.set.call_args[0][0]
    assert set_data['chunks'] == ["chunk1"]
    assert set_data['embeddings'] == [{'vector': [0.1]}]
    # ★★★ 修正: フィールド名を'cached_at'に修正 ★★★
    assert 'cached_at' in set_data

def test_search_with_vertex_ai_search(mocker):
    """_search_with_vertex_ai_search: 正常系のテスト"""
    mock_search_response = MagicMock()
    mock_result = MagicMock()
    mock_result.document.derived_struct_data = {"link": "http://example.com"}
    mock_search_response.results = [mock_result]
    
    mock_search_client = mocker.patch('gateway.main.discoveryengine.SearchServiceClient').return_value
    mock_search_client.search.return_value = mock_search_response
    
    results = gateway.main._search_with_vertex_ai_search("proj", "loc", "engine", "query")
    
    assert results == ["http://example.com"]
    mock_search_client.search.assert_called_once()


def test_scrape_text_from_url_success(mocker):
    """_scrape_text_from_url: 正常系のテスト"""
    mock_response = mocker.patch('requests.get').return_value
    mock_response.status_code = 200
    mock_response.text = "<html><body><p>Hello World</p></body></html>"
    
    text = gateway.main._scrape_text_from_url("http://example.com")
    
    assert "Hello World" in text


def test_scrape_text_from_url_skipped_domain():
    """_scrape_text_from_url: スキップ対象ドメインのテスト"""
    text = gateway.main._scrape_text_from_url("https://x.com/some_path")
    assert text == ""

def test_scrape_text_from_url_request_fails(mocker):
    """_scrape_text_from_url: requests.getが失敗するテスト"""
    mocker.patch('requests.get', side_effect=requests.exceptions.RequestException("Error"))
    text = gateway.main._scrape_text_from_url("http://example.com")
    assert text == ""


def test_generate_rag_based_advice_no_keywords(mocker):
    """_generate_rag_based_advice: キーワードが抽出できなかった場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="")
    # この関数が呼ばれないようにモックしておく
    mocker.patch('gateway.main._search_with_vertex_ai_search')
    
    advice = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")
    
    # ★★★ 修正: 実際の返り値に合わせる ★★★
    assert advice == ('関連する外部情報を見つけることができませんでした。', [])


def test_generate_rag_based_advice_no_search_results(mocker):
    """_generate_rag_based_advice: 検索結果がなかった場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="キーワード")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=[])
    
    advice = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")
    
    # ★★★ 修正: 実際の返り値に合わせる ★★★
    assert advice == ('関連する外部情報を見つけることができませんでした。', [])


def test_generate_rag_based_advice_success_flow(mocker, mock_generative_model):
    """_generate_rag_based_advice: 正常系のメインフローをテスト"""
    # --- 依存関係のモックを設定 ---
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="キーワード")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://example.com/page1"])
    # 1. キャッシュは最初は見つからない
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(None, None))
    # 2. スクレイピングは成功する
    mocker.patch('gateway.main._scrape_text_from_url', return_value="スクレイピングしたテキスト")
    # 3. 埋め込みベクトルも生成される
    mock_get_embeddings = mocker.patch('gateway.main._get_embeddings', return_value=[[0.1, 0.2]])
    # 4. キャッシュへの保存もモック
    mock_set_cache = mocker.patch('gateway.main._set_cached_chunks_and_embeddings')
    # 5. 最終的なアドバイス生成モデル
    mock_generative_model.generate_content.return_value.text = "最終的なアドバイスです。"

    # --- 関数を呼び出し ---
    advice, sources = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")

    # --- アサーション ---
    assert advice == "最終的なアドバイスです。"
    assert sources == ["http://example.com/page1"]

    # --- 各モックが期待通りに呼ばれたか検証 ---
    gateway.main._get_cached_chunks_and_embeddings.assert_called()
    gateway.main._scrape_text_from_url.assert_called_once_with("http://example.com/page1")
    mock_get_embeddings.assert_called()
    mock_set_cache.assert_called()
    mock_generative_model.generate_content.assert_called_once()
    # プロンプトにスクレイピングしたテキストが含まれていることを確認
    final_prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "スクレイピングしたテキスト" in final_prompt

def test_generate_rag_based_advice_with_cache(mocker, mock_generative_model):
    """_generate_rag_based_advice: キャッシュがヒットした場合のフローをテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="キーワード")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://cached-example.com/page2"])
    # 1. キャッシュが見つかる
    cached_chunks = ["キャッシュされたテキスト"]
    cached_embeddings = [[0.3, 0.4]]
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(cached_chunks, cached_embeddings))
    
    # ★★★ 修正: クエリの埋め込みベクトル生成もモックする ★★★
    mock_get_embeddings = mocker.patch('gateway.main._get_embeddings', return_value=[[0.3, 0.4]])
    
    # スクレイピングが呼ばれないようにモック
    mock_scrape = mocker.patch('gateway.main._scrape_text_from_url')
    
    mock_generative_model.generate_content.return_value.text = "キャッシュを使ったアドバイス"

    advice, sources = gateway.main._generate_rag_based_advice("query", "proj", "sim_id", "sug_id")

    assert advice == "キャッシュを使ったアドバイス"
    assert sources == ["http://cached-example.com/page2"]
    
    # キャッシュが使われたので、スクレイピングは呼ばれないはず
    mock_scrape.assert_not_called()
    # get_embeddingsはクエリの埋め込み取得で1回呼ばれる
    mock_get_embeddings.assert_called_once_with(["query"])

    # プロンプトにキャッシュされたテキストが含まれていることを確認
    final_prompt = mock_generative_model.generate_content.call_args[0][0]
    assert "キャッシュされたテキスト" in final_prompt


def test_verify_token_invalid(app, mocker):
    """_verify_token: トークン検証に失敗した場合のテスト"""
    mocker.patch('gateway.main.auth.verify_id_token', side_effect=ValueError("Invalid token"))
    mock_request = MagicMock()
    mock_request.headers.get.return_value = "Bearer invalid_token"
    
    # ★★★ 修正: アプリケーションコンテキスト内で実行 ★★★
    with app.test_request_context():
        response, status_code = gateway.main._verify_token(mock_request)
        assert status_code == 500
        assert response.get_json() == {"error": "Could not verify token"}

def test_verify_token_no_header(app, mocker):
    """_verify_token: Authorizationヘッダーがない場合のテスト"""
    mock_request = MagicMock()
    mock_request.headers.get.return_value = None
    
    # ★★★ 修正: アプリケーションコンテキスト内で実行 ★★★
    with app.test_request_context():
        response, status_code = gateway.main._verify_token(mock_request)
        assert status_code == 401
        assert response.get_json() == {"error": "Authorization header is missing"}

def test_create_cloud_task_success(mocker):
    """_create_cloud_task: 正常系のテスト"""
    # tasks_clientと関連するプロパティをモック
    mock_tasks_client = MagicMock()
    mocker.patch('gateway.main.tasks_client', mock_tasks_client)
    mocker.patch('gateway.main.project_id', "test-proj")
    mocker.patch('gateway.main.GCP_TASK_QUEUE_LOCATION', "test-loc")
    mocker.patch('gateway.main.GCP_TASK_QUEUE', "test-queue")
    mocker.patch('gateway.main.SERVICE_URL', "http://service.url")
    mocker.patch('gateway.main.GCP_TASK_SA_EMAIL', "sa@email.com")

    gateway.main._create_cloud_task({"key": "value"}, "/target")

    mock_tasks_client.create_task.assert_called_once()
    # taskオブジェクトの中身を部分的に検証
    task_arg = mock_tasks_client.create_task.call_args[1]['task']
    assert task_arg['http_request']['url'] == "http://service.url/target"
    assert task_arg['http_request']['oidc_token']['service_account_email'] == "sa@email.com"


def test_create_cloud_task_disabled(mocker):
    """_create_cloud_task: Cloud Tasksが無効な場合のテスト"""
    mocker.patch('gateway.main.tasks_client', None) # tasks_clientをNoneに設定
    mock_print = mocker.patch('builtins.print')

    gateway.main._create_cloud_task({"key": "value"}, "/target")
    
    # ★★★ 修正: 実際のエラーメッセージに合わせる ★★★
    mock_print.assert_any_call("⚠️ Cloud Tasks is not configured. Skipping task creation.")

def test_create_cloud_task_failure(mocker):
    """_create_cloud_task: タスク作成がAPIエラーで失敗した場合のテスト"""
    mock_tasks_client = MagicMock()
    mock_tasks_client.create_task.side_effect = Exception("API Error")
    mocker.patch('gateway.main.tasks_client', mock_tasks_client)
    mocker.patch('gateway.main.project_id', "test-proj")
    mocker.patch('gateway.main.GCP_TASK_QUEUE_LOCATION', "test-loc")
    mocker.patch('gateway.main.GCP_TASK_QUEUE', "test-queue")
    mocker.patch('gateway.main.SERVICE_URL', "http://service.url")
    mocker.patch('gateway.main.GCP_TASK_SA_EMAIL', "sa@email.com")
    mock_print = mocker.patch('builtins.print')
    mocker.patch('traceback.print_exc') # tracebackの出力を抑制

    gateway.main._create_cloud_task({"key": "value"}, "/target")

    mock_print.assert_any_call("❌ Failed to create Cloud Task for /target: API Error")


def test_update_graph_cache(mocker):
    """_update_graph_cache のテスト"""
    mock_generate = mocker.patch('gateway.main._get_graph_from_cache_or_generate')
    gateway.main._update_graph_cache("uid")
    mock_generate.assert_called_once_with("uid", force_regenerate=True)

def test_start_session_generation_fails(client, mocker):
    """POST /session/start: 最初の質問生成に失敗した場合のテスト"""
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.generate_initial_questions', return_value=None)
    # db_firestoreがNoneと評価されないようにモックを設定
    mocker.patch('gateway.main.db_firestore')

    response = client.post(
        '/api/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({'topic': '仕事の悩み'}),
        content_type='application/json'
    )

    assert response.status_code == 500
    assert response.get_json()['error'] == "Failed to generate initial questions"


def test_start_session_db_fails(client, mocker):
    """POST /session/start: Firestoreへの書き込みに失敗した場合のテスト"""
    mocker.patch('gateway.main._verify_token', return_value={'uid': MOCK_USER_ID})
    mocker.patch('gateway.main.generate_initial_questions', return_value=[{'question_text': q['question_text']} for q in MOCK_QUESTIONS])
    
    # Firestoreのbatch処理で例外を発生させる
    mock_db = mocker.patch('gateway.main.db_firestore')
    mock_db.batch.side_effect = Exception("DB Write Error")

    response = client.post(
        '/api/session/start',
        headers={'Authorization': f'Bearer {MOCK_ID_TOKEN}'},
        data=json.dumps({'topic': '仕事の悩み'}),
        content_type='application/json'
    )

    assert response.status_code == 500
    assert response.get_json()['error'] == "Failed to start session"


def test_search_books_from_api_success(mocker):
    """search_books_from_api: Google Books APIから正常に書籍情報を取得するテスト"""
    mock_response = MagicMock()
    mock_response.raise_for_status.return_value = None
    mock_response.json.return_value = {
        "items": [{
            "id": "test_id",
            "volumeInfo": {
                "title": "Test Book",
                "authors": ["Test Author"]
            }
        }]
    }
    mocker.patch('requests.get', return_value=mock_response)
    
    result = gateway.main.search_books_from_api("test", "dummy_key")
    
    assert len(result) == 1
    assert result[0]['id'] == 'test_id'
    assert result[0]['title'] == 'Test Book'

def test_search_books_from_api_request_fails(mocker):
    """search_books_from_api: Google Books APIリクエストが失敗した場合のテスト"""
    mocker.patch('requests.get', side_effect=requests.exceptions.RequestException("API Error"))
    
    results = gateway.main.search_books_from_api("query", "dummy_key")
    
    assert results == []

def test_search_books_from_api_malformed_response(mocker):
    """search_books_from_api: Google Books APIレスポンスの形式が不正だった場合のテスト"""
    mock_response = MagicMock()
    mock_response.raise_for_status.return_value = None
    mock_response.json.return_value = {"totalItems": 0} # 'items'キーがないレスポンス
    mocker.patch('requests.get', return_value=mock_response)
    
    results = gateway.main.search_books_from_api("query", "dummy_key")

    assert results == []

def test_generate_book_recommendations_no_keywords(mocker):
    """_generate_book_recommendations: キーワード抽出に失敗した場合のテスト"""
    mocker.patch('gateway.main._call_gemini_with_schema', return_value={"keywords": []})
    mock_search = mocker.patch('gateway.main.search_books_from_api')

    recommendations = gateway.main._generate_book_recommendations("insights", "dummy_key")
    
    assert recommendations == {"recommendations": []}
    mock_search.assert_not_called()

def test_generate_book_recommendations_no_search_results(mocker):
    """_generate_book_recommendations: 書籍検索結果が0件の場合のテスト"""
    mocker.patch('gateway.main._call_gemini_with_schema', return_value={"keywords": ["キーワード"]})
    mocker.patch('gateway.main.search_books_from_api', return_value=[])

    recommendations = gateway.main._generate_book_recommendations("insights", "dummy_key")
    
    assert recommendations == {"recommendations": []}

def test_generate_book_recommendations_gemini_reason_fails(mocker):
    """_generate_book_recommendations: 推薦理由の生成に失敗しても処理が継続するかのテスト"""
    mocker.patch('gateway.main._call_gemini_with_schema', return_value={"keywords": ["キーワード"]})
    mock_book_results = [{"id": "1", "title": "Test Book", "author": "Author"}]
    mocker.patch('gateway.main.search_books_from_api', return_value=mock_book_results)

    mock_model_instance = MagicMock()
    mock_model_instance.generate_content.side_effect = Exception("Gemini Error")
    mocker.patch('gateway.main.GenerativeModel', return_value=mock_model_instance)

    recommendations = gateway.main._generate_book_recommendations("insights", "dummy_key")
    
    assert recommendations == {"recommendations": []}

def test_generate_book_recommendations_success(mocker):
    """_generate_book_recommendations: 正常に書籍推薦が生成されるかのテスト"""
    mocker.patch('gateway.main._call_gemini_with_schema', return_value={"keywords": ["キーワード"]})
    mock_book_results = [{"id": "1", "title": "Test Book", "author": "Author"}]
    mocker.patch('gateway.main.search_books_from_api', return_value=mock_book_results)

    mock_model_instance = MagicMock()
    mock_response = MagicMock()
    mock_response.text = "This is a great book because..."
    mock_model_instance.generate_content.return_value = mock_response
    mocker.patch('gateway.main.GenerativeModel', return_value=mock_model_instance)

    recommendations = gateway.main._generate_book_recommendations("insights", "dummy_key")
    
    assert len(recommendations['recommendations']) == 1
    assert recommendations['recommendations'][0]['title'] == 'Test Book'
    assert recommendations['recommendations'][0]['reason'] == "This is a great book because..."


def test_get_embeddings_empty_list():
    """_get_embeddings: 空のリストを渡した際に空のリストが返るかのテスト"""
    result = gateway.main._get_embeddings([])
    assert result == []

def test_get_cached_chunks_and_embeddings_invalid_date(mocker):
    """_get_cached_chunks_and_embeddings: キャッシュの日付が無効な場合のテスト"""
    mock_doc = MagicMock()
    mock_doc.exists = True
    mock_doc.to_dict.return_value = {
        "cached_at": "not-a-datetime", # 無効な日付
        "chunks": ["chunk1"],
        "embeddings": [{"vector": [0.1]}]
    }
    mock_doc_ref = MagicMock()
    mock_doc_ref.get.return_value = mock_doc
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)

    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks is None
    assert embeddings is None

def test_get_cached_chunks_and_embeddings_data_mismatch(mocker):
    """_get_cached_chunks_and_embeddings: チャンクと埋め込みの数が一致しない場合のテスト"""
    mock_doc = MagicMock()
    mock_doc.exists = True
    now = datetime.now(timezone.utc)
    mock_doc.to_dict.return_value = {
        "cached_at": now,
        "chunks": ["chunk1", "chunk2"], # 2つ
        "embeddings": [{"vector": [0.1]}] # 1つ
    }
    mock_doc_ref = MagicMock()
    mock_doc_ref.get.return_value = mock_doc
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)
    
    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks is None
    assert embeddings is None

def test_get_cached_chunks_and_embeddings_db_error(mocker):
    """_get_cached_chunks_and_embeddings: Firestoreへのアクセスでエラーが発生した場合のテスト"""
    mock_doc_ref = MagicMock()
    mock_doc_ref.get.side_effect = Exception("DB Error")
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)

    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks is None
    assert embeddings is None

def test_set_cached_chunks_and_embeddings_no_data():
    """_set_cached_chunks_and_embeddings: 保存するデータがない場合に何もしないことのテスト"""
    # この関数はデータがないと早期リターンするので、呼び出してもエラーが出ないことを確認する
    try:
        gateway.main._set_cached_chunks_and_embeddings("http://example.com", [], [])
        gateway.main._set_cached_chunks_and_embeddings("http://example.com", ["chunk"], [])
        gateway.main._set_cached_chunks_and_embeddings("http://example.com", [], [[0.1]])
    except Exception as e:
        pytest.fail(f"Should not have raised an exception, but got {e}")

def test_generate_rag_based_advice_no_keywords(mocker):
    """_generate_rag_based_advice: キーワード抽出に失敗した場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="")
    # 検索クエリが元のクエリの一部になることを確認
    mock_search = mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=[])
    
    advice, sources = gateway.main._generate_rag_based_advice("test query", "proj", "engine1", "engine2")
    
    mock_search.assert_called()
    # 512文字に切り詰めたクエリで呼ばれているか
    assert mock_search.call_args[0][3] == "test query"
    assert advice == "関連する外部情報を見つけることができませんでした。"

def test_generate_rag_based_advice_no_urls_found(mocker):
    """_generate_rag_based_advice: Vertex AI SearchでURLが見つからなかった場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="keywords")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=[])
    
    advice, sources = gateway.main._generate_rag_based_advice("test query", "proj", "engine1", "engine2")
    
    assert advice == "関連する外部情報を見つけることができませんでした。"
    assert sources == []

def test_generate_rag_based_advice_scraping_fails(mocker):
    """_generate_rag_based_advice: スクレイピングと埋め込み生成に失敗した場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="keywords")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://example.com"])
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(None, None))
    mocker.patch('gateway.main._scrape_text_from_url', return_value="") # スクレイピング失敗
    
    advice, sources = gateway.main._generate_rag_based_advice("test query", "proj", "engine1", "engine2")
    
    assert advice == "関連する外部情報を見つけましたが、内容を読み取ることができませんでした。"
    assert "http://example.com" in sources

def test_generate_rag_based_advice_embedding_fails(mocker):
    """_generate_rag_based_advice: チャンクの埋め込み生成に失敗した場合のテスト"""
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="keywords")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://example.com"])
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(None, None))
    mocker.patch('gateway.main._scrape_text_from_url', return_value="some content")
    mocker.patch('gateway.main._get_embeddings', return_value=[]) # 埋め込み生成失敗
    
    advice, sources = gateway.main._generate_rag_based_advice("test query", "proj", "engine1", "engine2")

    assert advice == "関連する外部情報を見つけましたが、内容を読み取ることができませんでした。"

def test_generate_rag_based_advice_query_embedding_fails(mocker):
    """_generate_rag_based_advice: クエリの埋め込み生成に失敗した場合のテスト"""
    mocker.patch('threading.Thread') # バックグラウンドでのキャッシュ保存スレッドを無効化
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="keywords")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://example.com"])
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(None, None))
    mocker.patch('gateway.main._scrape_text_from_url', return_value="some content")
    
    # チャンクの埋め込みは成功するが、クエリの埋め込みで失敗するケース
    mocker.patch('gateway.main._get_embeddings', side_effect=[[[0.1, 0.2]], []]) 
    
    advice, sources = gateway.main._generate_rag_based_advice("test query", "proj", "engine1", "engine2")

    assert advice == "あなたの状況を分析できませんでした。もう一度お試しください。"


def test_get_cached_chunks_and_embeddings_stale(mocker):
    """_get_cached_chunks_and_embeddings: キャッシュが古い(stale)場合のテスト"""
    mock_doc = MagicMock()
    mock_doc.exists = True
    stale_date = datetime.now(timezone.utc) - timedelta(days=RAG_CACHE_TTL_DAYS + 1)
    mock_doc.to_dict.return_value = {
        "cached_at": stale_date,
        "chunks": ["chunk1"],
        "embeddings": [{"vector": [0.1]}]
    }
    mock_doc_ref = MagicMock()
    mock_doc_ref.get.return_value = mock_doc
    mocker.patch('gateway.main._get_url_cache_doc_ref', return_value=mock_doc_ref)

    chunks, embeddings = gateway.main._get_cached_chunks_and_embeddings("http://example.com")
    assert chunks is None
    assert embeddings is None

def test_generate_rag_based_advice_success_for_suggestions(mocker):
    """_generate_rag_based_advice: RAGによる提案生成(suggestions)が成功するかのテスト"""
    mocker.patch('threading.Thread') # バックグラウンドスレッドを無効化
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="keywords")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://example.com"])
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(None, None))
    mocker.patch('gateway.main._scrape_text_from_url', return_value="some content")
    mocker.patch('gateway.main._get_embeddings', side_effect=[[[0.1, 0.2]], [[0.1, 0.2]]]) 
    
    mock_model = MagicMock()
    mock_model.generate_content.return_value.text = "Generated Advice"
    mocker.patch('gateway.main.GenerativeModel', return_value=mock_model)

    advice, sources = gateway.main._generate_rag_based_advice(
        query="test query", 
        project_id="proj", 
        similar_cases_engine_id="engine1",
        suggestions_engine_id="engine2",
        rag_type="suggestions"
    )

    assert advice == "Generated Advice"
    assert "http://example.com" in sources
    final_prompt = mock_model.generate_content.call_args[0][0]
    assert "プロのカウンセラーです" in final_prompt # suggestions用のプロンプトか確認

def test_generate_rag_based_advice_success_for_similar_cases(mocker):
    """_generate_rag_based_advice: RAGによる提案生成(similar_cases)が成功するかのテスト"""
    mocker.patch('threading.Thread') # バックグラウンドスレッドを無効化
    mocker.patch('gateway.main._extract_keywords_for_search', return_value="keywords")
    mocker.patch('gateway.main._search_with_vertex_ai_search', return_value=["http://example.com"])
    mocker.patch('gateway.main._get_cached_chunks_and_embeddings', return_value=(None, None))
    mocker.patch('gateway.main._scrape_text_from_url', return_value="some content")
    mocker.patch('gateway.main._get_embeddings', side_effect=[[[0.1, 0.2]], [[0.1, 0.2]]]) 
    
    mock_model = MagicMock()
    mock_model.generate_content.return_value.text = "Generated Advice"
    mocker.patch('gateway.main.GenerativeModel', return_value=mock_model)

    advice, sources = gateway.main._generate_rag_based_advice(
        query="test query", 
        project_id="proj", 
        similar_cases_engine_id="engine1",
        suggestions_engine_id="engine2",
        rag_type="similar_cases"
    )

    assert advice == "Generated Advice"
    assert "http://example.com" in sources
    final_prompt = mock_model.generate_content.call_args[0][0]
    assert "聞き上手な友人です" in final_prompt # similar_cases用のプロンプトか確認