import os
import traceback
import firebase_admin
from firebase_admin import credentials, firestore
from vertexai.language_models import TextEmbeddingModel
from tenacity import retry, stop_after_attempt, wait_exponential

# --- GCP & Firebase 初期化 ---
try:
    print("Initializing Firebase Admin SDK...")
    firebase_admin.initialize_app()
    db = firestore.client()
    print("✅ Firebase Admin SDK initialized.")
except Exception as e:
    db = None
    print(f"❌ Error during initialization: {e}")
    traceback.print_exc()

# --- 定数定義 ---
USER_COLLECTION = 'users'
SESSIONS_COLLECTION = 'sessions'
ANALYSES_COLLECTION = 'analyses'
VECTOR_CACHE_COLLECTION = 'vector_cache' # ベクトル化した結果を保存するコレクション

@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(3))
def get_embeddings(texts: list[str]) -> list[list[float]]:
    """指定されたテキストのリストから埋め込みベクトルを取得する"""
    if not texts: return []
    model = TextEmbeddingModel.from_pretrained("text-multilingual-embedding-002")
    try:
        embeddings = model.get_embeddings(texts)
        return [embedding.values for embedding in embeddings]
    except Exception as e:
        print(f"❌ An error occurred during embedding generation: {e}")
        traceback.print_exc()
        raise

def _get_all_insights_for_user(user_id: str) -> str:
    """指定されたユーザーIDの全ての分析結果(insights)を1つのテキストに結合して返す"""
    if not db: return ""
    
    # gateway/main.py の _get_all_insights_as_text のロジックを流用
    sessions_ref = db.collection(USER_COLLECTION).document(user_id).collection(SESSIONS_COLLECTION).order_by('created_at').limit_to_last(20)
    sessions = sessions_ref.stream()
    all_insights = []
    
    print(f"  - Fetching insights for user: {user_id}")
    for session in sessions:
        try:
            session_data = session.to_dict()
            if not session_data: continue
            
            topic = str(session_data.get('topic', ''))
            title = str(session_data.get('title', ''))
            all_insights.append(f"--- セッション: {topic} ({title}) ---\n")
            
            analyses_ref = session.reference.collection(ANALYSES_COLLECTION).order_by('created_at')
            for analysis in analyses_ref.stream():
                analysis_data = analysis.to_dict()
                if analysis_data and isinstance(analysis_data.get('insights'), str):
                    all_insights.append(analysis_data['insights'] + "\n")
        except Exception as inner_e:
            print(f"  - Skipping potentially corrupted session {session.id} for user {user_id} due to error: {inner_e}")
            continue
            
    print(f"  - Found and combined insights for user: {user_id}")
    return "".join(all_insights)

def process_all_users_insights(request):
    """
    全てのユーザーの分析結果を集計し、ベクトル化して保存するCloud Function
    Cloud Schedulerによって定期的にトリガーされることを想定
    """
    # request 引数はCloud Functionsフレームワークによって渡されるが、この関数では利用しない
    print("--- Starting batch job: process_all_users_insights ---")
    if not db:
        print("❌ Firestore client is not available. Aborting.")
        # HTTPレスポンスを返すように修正
        return ("Firestore client not available", 500)


    try:
        users_ref = db.collection(USER_COLLECTION).stream()
        for user in users_ref:
            user_id = user.id
            print(f"Processing user: {user_id}")
            
            # 1. ユーザーの全てのセッションから分析結果(insights)を収集する (ロジックを実装)
            all_insights_text = _get_all_insights_for_user(user_id)

            # 2. 収集したテキストが空でなければ、ベクトル化を行う
            if all_insights_text:
                print(f"  - Generating embedding for user {user_id}...")
                vectors = get_embeddings([all_insights_text])
                
                # 3. ベクトル化されたデータをFirestoreに保存する
                if vectors:
                    vector_data = {
                        "user_id": user_id,
                        "embedding": vectors[0],
                        "source_text_digest": all_insights_text[:500], # 確認用
                        "updated_at": firestore.SERVER_TIMESTAMP
                    }
                    db.collection(VECTOR_CACHE_COLLECTION).document(user_id).set(vector_data)
                    print(f"  ✅ Successfully generated and saved embedding for user {user_id}")
            else:
                print(f"  - No insights found for user {user_id}. Skipping.")

    except Exception as e:
        print(f"❌ An unexpected error occurred in process_all_users_insights: {e}")
        traceback.print_exc()
        return ("An internal error occurred", 500)

    print("--- Finished batch job: process_all_users_insights ---")
    # 正常終了のレスポンスを返す
    return ("Successfully processed all users.", 200)



# ローカルでのテスト実行用（本番では使われない）
if __name__ == '__main__':
    # この関数を実行するには、ローカルでgcloud認証が必要です
    # gcloud auth application-default login
    print("Running locally for test...")
    process_all_users_insights(None, None)
    print("Local run finished.")