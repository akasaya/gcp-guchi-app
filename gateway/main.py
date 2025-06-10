import os
import firebase_admin
from firebase_admin import credentials, firestore, auth
from flask import Flask, request, jsonify
from flask_cors import CORS
import json
from tenacity import retry, stop_after_attempt, wait_exponential

import vertexai
from vertexai.generative_models import GenerativeModel, GenerationConfig

# --- GCP & Firebase 初期化 (推奨される方法に修正) ---
try:
    print("Initializing GCP services using Application Default Credentials...")
    
    # 引数なしで初期化することで、Cloud Run環境やローカルのgcloud設定から
    # 認証情報とプロジェクトIDを自動で取得します。
    firebase_admin.initialize_app()
    db_firestore = firestore.client()
    
    # 初期化されたアプリからプロジェクトIDを取得
    options = firebase_admin.get_app().options
    project_id = app_instance.project_id
    print(f"✅ Firebase Admin SDK initialized for project: {project_id}")

    # Vertex AIを初期化
    vertexai.init(project=project_id, location='asia-northeast1')
    print(f"✅ Vertex AI initialized for project: {project_id} in asia-northeast1")

except Exception as e:
    db_firestore = None
    print(f"❌ Error during initialization: {e}")
    # 本番環境で初期化に失敗したら、起動を中止してログにエラーを残します
    if 'K_SERVICE' in os.environ:
        raise

app = Flask(__name__)
# CORS設定: Firebase Hostingからのリクエストを明示的に許可
CORS(app, resources={r"/*": {"origins": "https://guchi-app-flutter.web.app"}})

# ===== JSONスキーマ定義 =====
QUESTIONS_SCHEMA = {
    "type": "object",
    "properties": {
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "question_text": {"type": "string"}
                },
                "required": ["question_text"]
            }
        }
    },
    "required": ["questions"]
}

SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {
            "type": "string",
            "description": "このセッション全体を要約する15文字程度の短いタイトル"
        },
        "insights": {
            "type": "string",
            "description": "指定されたMarkdown形式でのユーザーの心理分析レポート"
        }
    },
    "required": ["title", "insights"]
}

# ===== Gemini 呼び出しヘルパー関数 (リトライ機能付き) =====
@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(3))
def _call_gemini_with_schema(prompt: str, schema: dict) -> dict:
    """Geminiを構造化出力で呼び出し、JSONを返す。リトライ機能付き。"""
    model_name = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-001')
    model = GenerativeModel(model_name)
    
    attempt_num = _call_gemini_with_schema.retry.statistics.get('attempt_number', 1)
    print(f"--- Calling Gemini with schema (Attempt: {attempt_num}) ---")

    try:
        response = model.generate_content(
            prompt,
            generation_config=GenerationConfig(
                response_mime_type="application/json",
                response_schema=schema,
            ),
        )
        return json.loads(response.text)
    except Exception as e:
        print(f"Error on attempt {attempt_num}: {e}")
        raise

# ===== Gemini 呼び出しメイン関数 =====
def generate_initial_questions(topic):
    prompt = f"""
あなたは、ユーザーの悩みに寄り添う、思慮深いカウンセラーです。
ユーザーが選択したトピック「{topic}」について、対話を深めるための「はい」か「いいえ」で答えられる質問を5つ生成してください。
質問は、前の質問からの流れを汲み、徐々に核心に迫るように構成してください。
"""
    try:
        data = _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA)
        return data.get("questions", [])
    except Exception as e:
        print(f"Failed to generate initial questions after retries: {e}")
        return [{"question_text": q} for q in [
            "最近、特にストレスを感じることはありますか？", "何か新しい挑戦をしたいと思っていますか？", "自分の時間をもっと大切にしたいですか？",
            "人間関係で何か改善したい点はありますか？", "今の生活に満足していますか？"
        ]]

def generate_follow_up_questions(insights):
    prompt = f"""
あなたは、ユーザーの悩みに寄り添う、思慮深いカウンセラーです。
ユーザーとのこれまでの対話から、あなたは以下のような深い洞察を得ました。

# あなたの分析(洞察)
{insights}

この洞察をさらに深め、ユーザーが自身の気持ちをより明確に理解できるよう、核心に迫る「はい」か「いいえ」で答えられる質問を新たに5つ生成してください。
質問は、分析結果から浮かび上がったテーマや葛藤に直接関連するものにしてください。
"""
    data = _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA)
    return data.get("questions", [])

def generate_summary_and_title(topic, swipes_text):
    prompt = f"""
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
    return _call_gemini_with_schema(prompt, SUMMARY_SCHEMA)

# ===== API Routes =====
@app.route('/session/start', methods=['POST'])
def start_session():
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        return jsonify({'error': 'Token verification failed', 'details': str(e)}), 500

    data = request.get_json()
    if not data or 'topic' not in data:
        return jsonify({'error': 'Topic is required in request body'}), 400
    topic = data['topic']

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500

    try:
        questions = generate_initial_questions(topic)
        if not questions or len(questions) < 1:
            raise Exception("AI failed to generate sufficient questions.")

        user_doc_ref = db_firestore.collection('users').document(user_id)
        session_doc_ref = user_doc_ref.collection('sessions').document()
        
        session_doc_ref.set({
            'topic': topic,
            'status': 'in_progress',
            'created_at': firestore.SERVER_TIMESTAMP,
            'turn': 1,
            'max_turns': 3,
        })
        session_id = session_doc_ref.id

        questions_collection = session_doc_ref.collection('questions')
        question_docs_for_frontend = []
        for i, q_data in enumerate(questions):
            q_text = q_data.get("question_text")
            if q_text and q_text.strip():
                q_doc_ref = questions_collection.document()
                q_doc_ref.set({
                    'text': q_text,
                    'order': i,
                    'turn': 1
                })
                question_docs_for_frontend.append({
                    'question_id': q_doc_ref.id,
                    'question_text': q_text
                })
        
        if not question_docs_for_frontend:
             raise Exception("All generated questions were empty.")

        return jsonify({
            'session_id': session_id,
            'questions': question_docs_for_frontend
        }), 200

    except Exception as e:
        print(f"Error in start_session: {e}")
        return jsonify({'error': 'Failed to start session', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/swipe', methods=['POST'])
def record_swipe(session_id):
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        return jsonify({'error': 'Token verification failed', 'details': str(e)}), 500

    data = request.get_json()
    if not data: return jsonify({'error': 'Request body is missing'}), 400

    question_id = data.get('question_id')
    answer = data.get('answer')
    hesitation_time = data.get('hesitation_time')
    speed = data.get('speed')
    turn = data.get('turn')

    if not all([question_id, answer, turn]):
        return jsonify({'error': 'Missing required fields in swipe data (question_id, answer, turn)'}), 400

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500

    try:
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        
        swipes_collection = session_doc_ref.collection('swipes')
        swipes_collection.add({
            'question_id': question_id,
            'question_ref': session_doc_ref.collection('questions').document(question_id),
            'answer': answer,
            'hesitation_time_sec': hesitation_time,
            'swipe_duration_ms': speed,
            'turn': turn,
            'timestamp': firestore.SERVER_TIMESTAMP
        })
        
        return jsonify({'status': 'swipe_recorded'}), 200

    except Exception as e:
        print(f"Error recording swipe: {e}")
        return jsonify({'error': 'Failed to record swipe', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/summary', methods=['POST'])
def post_summary(session_id):
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token)
        user_id = decoded_token['uid']
    except Exception as e:
        return jsonify({'error': 'Token verification failed', 'details': str(e)}), 500

    data = request.get_json()
    if not data or 'swipes' not in data:
        return jsonify({'error': 'Swipes data is required in request body'}), 400
    swipes_from_frontend = data['swipes']

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500

    try:
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        session_doc = session_doc_ref.get()
        if not session_doc.exists:
            return jsonify({'error': 'Session not found'}), 404
        
        session_data = session_doc.to_dict()
        topic = session_data.get('topic', '不明なトピック')
        current_turn = session_data.get('turn', 1)
        max_turns = session_data.get('max_turns', 3)

        swipes_text_list = []
        for swipe in swipes_from_frontend:
            q_text = swipe.get('question_text', '不明な質問')
            answer_bool = swipe.get('answer', False)
            answer_text = "はい" if answer_bool else "いいえ"
            hesitation = swipe.get('hesitation_time', 0)
            
            hesitation_comment = ""
            if hesitation >= 3.0:
                hesitation_comment = f"（回答に{hesitation:.1f}秒かかっており、特に迷いが見られました）"

            swipes_text_list.append(f"Q: {q_text}\nA: {answer_text} {hesitation_comment}")
        swipes_text = "\n".join(swipes_text_list)
        
        summary_data = generate_summary_and_title(topic, swipes_text)
        insights_md = summary_data.get('insights')
        title = summary_data.get('title')
        if not insights_md or not title:
            raise Exception("AI failed to generate summary or title.")

        analyses_collection = session_doc_ref.collection('analyses')
        analyses_collection.add({
            'turn': current_turn,
            'insights': insights_md,
            'created_at': firestore.SERVER_TIMESTAMP
        })
        
        session_update_data = {
            'status': 'completed',
            'updated_at': firestore.SERVER_TIMESTAMP,
            'latest_insights': insights_md
        }
        if current_turn == 1:
            session_update_data['title'] = title
        
        session_doc_ref.update(session_update_data)
        
        return jsonify({
            'title': title,
            'insights': insights_md,
            'turn': current_turn,
            'max_turns': max_turns
        }), 200

    except Exception as e:
        print(f"Error in post_summary: {e}")
        return jsonify({'error': 'Failed to generate summary', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/continue', methods=['POST'])
def continue_session(session_id):
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token)
        user_id = decoded_token['uid']
    except Exception as e:
        return jsonify({'error': 'Token verification failed', 'details': str(e)}), 500

    data = request.get_json()
    if not data or 'insights' not in data:
        return jsonify({'error': 'Insights are required'}), 400
    
    insights = data['insights']

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500

    try:
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        
        @firestore.transactional
        def update_turn_in_transaction(transaction, session_ref):
            snapshot = session_ref.get(transaction=transaction)
            if not snapshot.exists:
                raise Exception("Session not found in transaction")
            
            session_data = snapshot.to_dict()
            current_turn = session_data.get('turn', 1)
            max_turns = session_data.get('max_turns', 3)
            
            if current_turn >= max_turns:
                raise Exception(f"Cannot continue session. Maximum turns ({max_turns}) reached.")

            new_turn = current_turn + 1
            
            transaction.update(session_ref, {
                'status': 'in_progress',
                'updated_at': firestore.SERVER_TIMESTAMP,
                'turn': new_turn
            })
            return new_turn

        transaction = db_firestore.transaction()
        new_turn = update_turn_in_transaction(transaction, session_doc_ref)

        questions = generate_follow_up_questions(insights=insights)
        if not questions or len(questions) < 1:
            raise Exception("AI failed to generate sufficient follow-up questions.")

        questions_collection = session_doc_ref.collection('questions')

        last_question_query = questions_collection.order_by('order', direction=firestore.Query.DESCENDING).limit(1).stream()
        last_order = -1
        for q in last_question_query:
            last_order = q.to_dict().get('order', -1)
        start_order = last_order + 1

        question_docs_for_frontend = []
        for i, q_data in enumerate(questions):
            q_text = q_data.get("question_text")
            if q_text and q_text.strip():
                q_doc_ref = questions_collection.document()
                q_doc_ref.set({
                    'text': q_text,
                    'turn': new_turn,
                    'order': start_order + i,
                    'created_at': firestore.SERVER_TIMESTAMP
                })
                question_docs_for_frontend.append({
                    'question_id': q_doc_ref.id,
                    'question_text': q_text
                })
        
        if not question_docs_for_frontend:
             raise Exception("All generated follow-up questions were empty.")

        return jsonify({
            'session_id': session_id,
            'questions': question_docs_for_frontend,
            'turn': new_turn
        }), 200

    except Exception as e:
        print(f"Error in continue_session: {e}")
        return jsonify({'error': 'Failed to continue session', 'details': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)