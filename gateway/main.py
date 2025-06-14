import firebase_admin
from firebase_admin import credentials, firestore, auth
from flask import Flask, request, jsonify
from flask_cors import CORS

import os
import json
import re
import traceback
import threading

from tenacity import retry, stop_after_attempt, wait_exponential
import vertexai
from vertexai.generative_models import GenerativeModel, GenerationConfig

# --- GCP & Firebase 初期化 ---
try:
    print("Initializing GCP services using Application Default Credentials...")
    firebase_admin.initialize_app()
    db_firestore = firestore.client()
    
    app_instance = firebase_admin.get_app()
    project_id = app_instance.project_id
    print(f"✅ Firebase Admin SDK initialized for project: {project_id}")

    vertex_ai_region = os.getenv('GCP_VERTEX_AI_REGION', 'us-central1')
    vertexai.init(project=project_id, location=vertex_ai_region)
    print(f"✅ Vertex AI initialized for project: {project_id} in {vertex_ai_region}")

except Exception as e:
    db_firestore = None
    print(f"❌ Error during initialization: {e}")
    traceback.print_exc()
    if 'K_SERVICE' in os.environ:
        raise

app = Flask(__name__)
# --- CORS設定 ---
prod_origin = "https://guchi-app-flutter.web.app"
if 'K_SERVICE' in os.environ:
    origins = [prod_origin]
else:
    origins = [
        prod_origin,
        re.compile(r"http://localhost:.*"),
        re.compile(r"http://127.0.0.1:.*"),
    ]
CORS(app, resources={r"/*": {"origins": origins}})

# ===== JSONスキーマ定義 =====
QUESTIONS_SCHEMA = {
    "type": "object",
    "properties": {
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"question_text": {"type": "string"}},
                "required": ["question_text"]
            }
        }
    },
    "required": ["questions"]
}

# 【復活】要約生成専用のスキーマ
SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string", "description": "このセッション全体を要約する15文字程度の短いタイトル"},
        "insights": {"type": "string", "description": "指定されたMarkdown形式でのユーザーの心理分析レポート"}
    },
    "required": ["title", "insights"]
}

GRAPH_SCHEMA = {
    "type": "object",
    "properties": {
        "nodes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "type": {"type": "string", "enum": ["emotion", "topic", "keyword", "issue"]},
                    "size": {"type": "integer"}
                },
                "required": ["id", "type", "size"]
            }
        },
        "edges": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "source": {"type": "string"},
                    "target": {"type": "string"},
                    "weight": {"type": "integer"}
                },
                "required": ["source", "target", "weight"]
            }
        }
    },
    "required": ["nodes", "edges"]
}

# ===== プロンプトテンプレート =====

# 【復活】要約生成専用のプロンプト
SUMMARY_ONLY_PROMPT_TEMPLATE = """
あなたは、ユーザーの感情の動きを分析するプロの臨床心理士です。
ユーザーは「{topic}」というテーマについて対話しています。
以下のユーザーとの会話履歴を分析し、必ず指示通りのJSON形式で分析レポートとタイトルを出力してください。

# 分析対象の会話履歴
{swipes_text}

# 出力形式 (JSON)
必ず以下のキーを持つJSONオブジェクトを生成してください。
- `title`: 会話全体を象徴する15文字程度の短いタイトル。
- `insights`: 以下のMarkdown形式で記述された分析レポート。

```markdown
## 全体的な要約
ここに1〜2行でユーザーの状態の要約を記述します。

## 詳細
### ユーザーの感情
ここに「ポジティブ」「ネガティブ」「葛藤している」など、感情の状態を記述します。

### 詳細な分析
+ （ここに具体的な願いや思考に関する分析を箇条書きで記述）
+ （会話履歴に「特に迷いが見られました」と記載のある回答は、ユーザーがためらいや葛藤を抱えている可能性があります。その点を中心に、なぜ迷ったのかを深く考察してください）

### 総括
ここに全体をまとめた結論や、次へのアドバイスを記述します。
```
"""

GRAPH_ANALYSIS_PROMPT_TEMPLATE = """
あなたはデータサイエンティストであり、臨床心理士でもあります。
これから渡すテキストは、あるユーザーの複数回のカウンセリングセッション（ココロヒモトク）の記録です。
この記録全体を分析し、ユーザーの心理状態の核となる要素（感情、悩み、トピック、重要なキーワード）を抽出し、それらの関連性を表現するグラフデータを生成してください。
出力は、以下の仕様に厳密に従ったJSON形式のみとしてください。説明や前置きは一切不要です。
【出力JSONの仕様】
★★★重要: `id` は必ず日本語の単語または短いフレーズにしてください。ローマ字や英語は使用しないでください。★★★
{ "nodes": [ ... ], "edges": [ ... ] }
【分析のヒント】
...
【セッション記録】
"""

CHAT_PROMPT_TEMPLATE = """
あなたは、ユーザーの心理分析の専門家であり、共感力と洞察力に優れたカウンセラーです。
...
"""

# ===== Gemini ヘルパー関数群 =====
@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(3))
def _call_gemini_with_schema(prompt: str, schema: dict, model_name: str) -> dict:
    model = GenerativeModel(model_name)
    attempt_num = _call_gemini_with_schema.retry.statistics.get('attempt_number', 1)
    print(f"--- Calling Gemini ({model_name}) with schema (Attempt: {attempt_num}) ---")
    response_text = ""
    try:
        response = model.generate_content(prompt, generation_config=GenerationConfig(response_mime_type="application/json", response_schema=schema))
        response_text = response.text
        json_start = response_text.find('{')
        json_end = response_text.rfind('}')
        if json_start != -1 and json_end != -1 and json_end > json_start:
            return json.loads(response_text[json_start:json_end+1])
        return json.loads(response_text)
    except Exception as e:
        print(f"Error on attempt {attempt_num} with model {model_name}: {e}\n--- Gemini Response ---\n{response_text if response_text else 'Empty'}\n---")
        traceback.print_exc()
        raise

def generate_initial_questions(topic):
    prompt = f"あなたはカウンセラーです。トピック「{topic}」について、「はい」か「いいえ」で答えられる質問を5つ生成してください。"
    try:
        flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
        data = _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA, model_name=flash_model)
        return data.get("questions", [])
    except Exception as e:
        print(f"Failed to generate initial questions: {e}")
        return [{"question_text": "最近、特にストレスを感じることはありますか？"}] # Fallback

# 【復活】深掘り質問を生成する専用の関数
def generate_follow_up_questions(insights):
    prompt = f"""
あなたはカウンセラーです。以下の分析結果をさらに深める、「はい」か「いいえ」で答えられる質問を5つ生成してください。
# 分析結果
{insights}
"""
    flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
    data = _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA, model_name=flash_model)
    return data.get("questions", [])

# 【復活】要約とタイトルのみを生成する高速な関数
def generate_summary_only(topic, swipes_text):
    prompt = SUMMARY_ONLY_PROMPT_TEMPLATE.format(topic=topic, swipes_text=swipes_text)
    flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
    return _call_gemini_with_schema(prompt, SUMMARY_SCHEMA, model_name=flash_model)

def generate_graph_data(all_insights_text):
    prompt = GRAPH_ANALYSIS_PROMPT_TEMPLATE + all_insights_text
    pro_model = os.getenv('GEMINI_PRO_NAME', 'gemini-1.5-pro-preview-05-20')
    return _call_gemini_with_schema(prompt, GRAPH_SCHEMA, model_name=pro_model)

def generate_chat_response(session_summary, chat_history, user_message):
    history_str = "\n".join([f"{msg['author']}: {msg['text']}" for msg in chat_history])
    prompt = CHAT_PROMPT_TEMPLATE.format(session_summary=session_summary, chat_history=history_str, user_message=user_message)
    pro_model = os.getenv('GEMINI_PRO_NAME', 'gemini-1.5-pro-preview-05-20')
    model = GenerativeModel(pro_model)
    response = model.generate_content(prompt)
    return response.text.strip()

# --- バックグラウンド処理 ---

# 【新規追加】次の質問を裏側で生成し、Firestoreに保存する関数
def _prefetch_questions_and_save(session_id: str, user_id: str, insights_md: str, current_turn: int, max_turns: int):
    print(f"--- Triggered question prefetch for user: {user_id}, session: {session_id}, next_turn: {current_turn + 1} ---")
    if current_turn >= max_turns:
        print("Max turns reached. Skipping question prefetch.")
        return
    try:
        questions = generate_follow_up_questions(insights=insights_md)
        if not questions:
            print(f"⚠️ AI failed to generate prefetch questions for session {session_id}.")
            return

        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        next_turn = current_turn + 1
        questions_collection = session_doc_ref.collection('questions')
        
        last_question_query = questions_collection.order_by('order', direction=firestore.Query.DESCENDING).limit(1).stream()
        last_order = next(last_question_query, None)
        start_order = last_order.to_dict().get('order', -1) + 1 if last_order else 0

        batch = db_firestore.batch()
        count = 0
        for i, q_data in enumerate(questions):
            if q_text := q_data.get("question_text"):
                q_doc_ref = questions_collection.document()
                batch.set(q_doc_ref, {'text': q_text, 'turn': next_turn, 'order': start_order + i, 'created_at': firestore.SERVER_TIMESTAMP, 'is_prefetched': True})
                count += 1
        batch.commit()
        print(f"✅ Successfully prefetched and saved {count} questions for turn {next_turn}.")
    except Exception as e:
        print(f"❌ Failed to prefetch questions for session {session_id}: {e}")
        traceback.print_exc()

def _update_graph_cache(user_id: str):
    print(f"--- Triggered graph cache update for user: {user_id} ---")
    try:
        all_insights_text = _get_all_insights_as_text(user_id)
        if not all_insights_text: return
        
        raw_graph_data = generate_graph_data(all_insights_text)
        
        # データサニタイズ
        nodes = raw_graph_data.get('nodes', [])
        edges = raw_graph_data.get('edges', [])
        sanitized_nodes = [n for n in nodes if isinstance(n, dict) and n.get('id')]
        valid_node_ids = {n['id'] for n in sanitized_nodes}
        sanitized_edges = [e for e in edges if isinstance(e, dict) and e.get('source') in valid_node_ids and e.get('target') in valid_node_ids]

        final_graph_data = {"nodes": sanitized_nodes, "edges": sanitized_edges}
        cache_doc_ref = db_firestore.collection('users').document(user_id).collection('analysis').document('graph_cache')
        cache_doc_ref.set({'data': final_graph_data, 'updated_at': firestore.SERVER_TIMESTAMP})
        print(f"✅ Successfully updated graph cache for user: {user_id}")
    except Exception as e:
        print(f"❌ Failed to update graph cache for user {user_id}: {e}")
        traceback.print_exc()

# ===== 認証ヘルパー =====
def _verify_token(request):
    auth_header = request.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        raise auth.InvalidIdTokenError("Authorization token is missing or invalid")
    id_token = auth_header.split('Bearer ')[1]
    return auth.verify_id_token(id_token, clock_skew_seconds=15)

# ===== API Routes =====
@app.route('/session/start', methods=['POST'])
def start_session():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        
        data = request.get_json()
        if not data or 'topic' not in data: 
            return jsonify({'error': 'Topic is required'}), 400
        topic = data['topic']

        questions = generate_initial_questions(topic)
        if not questions: 
            raise Exception("AI failed to generate questions.")

        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document()
        session_doc_ref.set({'topic': topic, 'status': 'in_progress', 'created_at': firestore.SERVER_TIMESTAMP, 'turn': 1, 'max_turns': 3})
        
        questions_collection = session_doc_ref.collection('questions')
        question_docs = []
        for i, q_data in enumerate(questions):
            if q_text := q_data.get("question_text"):
                q_doc_ref = questions_collection.document()
                q_doc_ref.set({'text': q_text, 'order': i, 'turn': 1})
                question_docs.append({'question_id': q_doc_ref.id, 'question_text': q_text})
        
        if not question_docs: 
            raise Exception("All generated questions were empty.")
        
        return jsonify({'session_id': session_doc_ref.id, 'questions': question_docs}), 200
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in start_session: {e}")
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Error in start_session: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to start session', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/swipe', methods=['POST'])
def record_swipe(session_id):
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        
        data = request.get_json()
        if not data: return jsonify({'error': 'Request body is missing'}), 400

        question_id = data.get('question_id')
        answer = data.get('answer') 
        hesitation_time = data.get('hesitation_time')
        speed = data.get('speed')
        turn = data.get('turn')

        if not all([question_id, turn is not None]) or not isinstance(answer, bool):
            return jsonify({'error': 'Missing or invalid type for required fields in swipe data'}), 400

        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        
        session_doc_ref.collection('swipes').add({
            'question_id': question_id,
            'answer': answer,
            'hesitation_time_sec': hesitation_time,
            'swipe_duration_ms': speed,
            'turn': turn,
            'timestamp': firestore.SERVER_TIMESTAMP
        })
        
        return jsonify({'status': 'swipe_recorded'}), 200
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in record_swipe: {e}")
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Error recording swipe: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to record swipe', 'details': str(e)}), 500


# 【全面改修】タイムアウトしないように、重い処理を全てバックグラウンドに移動
@app.route('/session/<string:session_id>/summary', methods=['POST'])
def post_summary(session_id):
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        data = request.get_json()
        if not data or 'swipes' not in data: return jsonify({'error': 'Swipes data is required'}), 400
        
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        session_doc = session_doc_ref.get()
        if not session_doc.exists: return jsonify({'error': 'Session not found'}), 404
        
        session_data = session_doc.to_dict()
        topic = session_data.get('topic', '不明')
        current_turn = session_data.get('turn', 1)
        max_turns = session_data.get('max_turns', 3)
        
        swipes_text = "\n".join([f"Q: {s.get('question_text')}\nA: {'はい' if s.get('answer') else 'いいえ'}" for s in data['swipes']])

        # 1. 要約のみを高速に生成
        summary_data = generate_summary_only(topic, swipes_text)
        insights_md = summary_data.get('insights')
        title = summary_data.get('title')
        if not insights_md or not title: raise Exception("AI failed to generate summary or title.")

        # 2. 要約をDBに保存
        session_doc_ref.collection('analyses').add({'turn': current_turn, 'insights': insights_md, 'created_at': firestore.SERVER_TIMESTAMP})
        update_data = {'status': 'completed', 'updated_at': firestore.SERVER_TIMESTAMP, 'latest_insights': insights_md}
        if current_turn == 1: update_data['title'] = title
        session_doc_ref.update(update_data)

        # 3. 重い処理をバックグラウンドで開始
        threading.Thread(target=_update_graph_cache, args=(user_id,)).start()
        threading.Thread(target=_prefetch_questions_and_save, args=(session_id, user_id, insights_md, current_turn, max_turns)).start()
        print("--- Started background threads for graph cache and question prefetch. ---")
        
        # 4. すぐにレスポンスを返す
        return jsonify({'title': title, 'insights': insights_md, 'turn': current_turn, 'max_turns': max_turns}), 200

    except Exception as e:
        print(f"Error in post_summary: {e}")
        return jsonify({'error': 'Failed to generate summary', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/continue', methods=['POST'])
def continue_session(session_id):
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        
        @firestore.transactional
        def update_turn(transaction, ref):
            snapshot = ref.get(transaction=transaction)
            if not snapshot.exists: raise Exception("Session not found")
            data = snapshot.to_dict()
            if data.get('turn', 1) >= data.get('max_turns', 3): raise Exception("Max turns reached.")
            new_turn = data.get('turn', 1) + 1
            transaction.update(ref, {'status': 'in_progress', 'turn': new_turn, 'updated_at': firestore.SERVER_TIMESTAMP})
            return new_turn
        
        transaction = db_firestore.transaction()
        new_turn = update_turn(transaction, session_doc_ref)

        questions_collection = session_doc_ref.collection('questions')
        query = questions_collection.where('turn', '==', new_turn).order_by('order')
        question_docs = [{'question_id': doc.id, 'question_text': doc.to_dict().get('text')} for doc in query.stream()]

        if not question_docs:
            print(f"⚠️ Prefetched questions not found for turn {new_turn}. Generating and SAVING now (fallback).")
            last_analysis_doc = next(session_doc_ref.collection('analyses').order_by('created_at', direction=firestore.Query.DESCENDING).limit(1).stream(), None)
            if not last_analysis_doc: raise Exception("Cannot generate fallback questions: no analysis found.")
            
            fallback_questions = generate_follow_up_questions(last_analysis_doc.to_dict().get('insights'))
            if not fallback_questions: raise Exception("AI failed to generate fallback questions.")

            # --- ここからが修正の核心部分です ---
            # フォールバックで生成した質問も、必ずDBに保存してからユーザーに返す
            last_question_query = questions_collection.order_by('order', direction=firestore.Query.DESCENDING).limit(1).stream()
            last_order = next(last_question_query, None)
            start_order = last_order.to_dict().get('order', -1) + 1 if last_order else 0

            batch = db_firestore.batch()
            for i, q_data in enumerate(fallback_questions):
                if q_text := q_data.get("question_text"):
                    # DBに保存するための新しいドキュメントIDを作成
                    q_doc_ref = questions_collection.document()
                    batch.set(q_doc_ref, {
                        'text': q_text,
                        'turn': new_turn,
                        'order': start_order + i,
                        'created_at': firestore.SERVER_TIMESTAMP,
                        'is_prefetched': False # フォールバックで生成されたことを示す
                    })
                    # DBに保存するIDと同じIDを使って、フロントに返すデータを作成
                    question_docs.append({
                        'question_id': q_doc_ref.id,
                        'question_text': q_text
                    })
            batch.commit() # DBへの保存を確定
            print(f"✅ Saved {len(fallback_questions)} fallback questions to Firestore.")
            # --- 修正の核心部分ここまで ---
        
        if not question_docs: raise Exception("Failed to get any questions for the user.")
        return jsonify({'session_id': session_id, 'questions': question_docs, 'turn': new_turn}), 200
    except Exception as e:
        print(f"Error in continue_session: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to continue session', 'details': str(e)}), 500

# --- 分析系API ---

def _get_all_insights_as_text(user_id: str) -> str:
    if not db_firestore: return ""
    sessions_ref = db_firestore.collection('users').document(user_id).collection('sessions').order_by('created_at').limit_to_last(20)
    
    # ★★★ 修正点2: .stream() を .get() に変更 ★★★
    sessions = sessions_ref.get() 

    all_insights = []
    for session in sessions:
        try:
            session_data = session.to_dict()
            if not session_data: continue

            topic = str(session_data.get('topic', ''))
            title = str(session_data.get('title', ''))
            all_insights.append(f"--- セッション: {topic} ({title}) ---\n")

            analyses_ref = session.reference.collection('analyses').order_by('created_at')
            for analysis in analyses_ref.stream():
                analysis_data = analysis.to_dict()
                if analysis_data and isinstance(analysis_data.get('insights'), str):
                    all_insights.append(analysis_data['insights'] + "\n")
        except Exception as inner_e:
            print(f"Skipping potentially corrupted session {session.id} for insight aggregation due to error: {inner_e}")
            continue
    
    return "".join(all_insights)

@app.route('/analysis/chat', methods=['POST'])
def post_chat_message():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        data = request.get_json()
        if not data or not (user_message := data.get('message')): return jsonify({'error': 'message is required'}), 400
        
        session_summary = _get_all_insights_as_text(user_id)
        if not session_summary:
            ai_response = "こんにちは。分析できるセッション履歴がまだないようです。まずはセッションを完了して、ご自身の内面を探る旅を始めてみましょう。"
        else:
            ai_response = generate_chat_response(session_summary, data.get('chat_history', []), user_message)
        return jsonify({'response': ai_response})
    except Exception as e:
        print(f"Error in post_chat_message: {e}")
        return jsonify({"error": "An internal error occurred."}), 500

@app.route('/analysis/graph', methods=['GET'])
def get_analysis_graph():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        cache_doc_ref = db_firestore.collection('users').document(user_id).collection('analysis').document('graph_cache')
        cache_doc = cache_doc_ref.get()
        if cache_doc.exists:
            return jsonify(cache_doc.to_dict().get('data', {"nodes": [], "edges": []}))
        else:
            print(f"--- No graph cache for user: {user_id}. Returning empty and triggering update. ---")
            threading.Thread(target=_update_graph_cache, args=(user_id,)).start()
            return jsonify({"nodes": [], "edges": []})
    except Exception as e:
        print(f"Error in get_analysis_graph: {e}")
        return jsonify({"error": "An internal error occurred."}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)