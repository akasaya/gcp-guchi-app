import os
import firebase_admin
from firebase_admin import credentials, firestore, auth
from flask import Flask, request, jsonify
from flask_cors import CORS
import json
from dotenv import load_dotenv
from pathlib import Path
from tenacity import retry, stop_after_attempt, wait_exponential

import vertexai
from vertexai.generative_models import GenerativeModel, GenerationConfig
from google.oauth2 import service_account

# .envファイルのパスを明示的に指定して読み込む
dotenv_path = Path(__file__).parent / '.env'
load_dotenv(dotenv_path=dotenv_path)


# --- (Firebase, Vertex AIの初期化処理は変更なし) ---
try:
    firebase_project_id = os.getenv('FIREBASE_PROJECT_ID')
    firebase_credentials_path_str = os.getenv('FIREBASE_CREDENTIALS_PATH')
    if not firebase_project_id or not firebase_credentials_path_str:
        raise ValueError("FIREBASE_PROJECT_ID and FIREBASE_CREDENTIALS_PATH must be set in .env file")
    
    base_path = Path(__file__).parent
    firebase_credentials_path = (base_path / firebase_credentials_path_str).resolve()
    
    if not firebase_credentials_path.is_file():
         raise FileNotFoundError(f"Firebase credentials file not found at: {firebase_credentials_path}")

    cred = credentials.Certificate(str(firebase_credentials_path))
    firebase_admin.initialize_app(cred, {'projectId': firebase_project_id})
    db_firestore = firestore.client()
    print(f"✅ Firebase Admin SDK initialized for project: {firebase_project_id}")
except Exception as e:
    db_firestore = None
    print(f"❌ Error initializing Firebase Admin SDK: {e}")

try:
    vertex_ai_project_id = os.getenv('VERTEX_AI_PROJECT_ID')
    vertex_ai_credentials_path_str = os.getenv('VERTEX_AI_CREDENTIALS_PATH')
    vertex_ai_location = os.getenv('VERTEX_AI_LOCATION', 'asia-northeast1')
    if not vertex_ai_project_id or not vertex_ai_credentials_path_str:
        raise ValueError("VERTEX_AI_PROJECT_ID and VERTEX_AI_CREDENTIALS_PATH must be set in .env file")

    base_path = Path(__file__).parent
    vertex_ai_credentials_path = (base_path / vertex_ai_credentials_path_str).resolve()
    if not vertex_ai_credentials_path.is_file():
         raise FileNotFoundError(f"Vertex AI credentials file not found at: {vertex_ai_credentials_path}")

    vertex_credentials = service_account.Credentials.from_service_account_file(str(vertex_ai_credentials_path))
    vertexai.init(project=vertex_ai_project_id, location=vertex_ai_location, credentials=vertex_credentials)
    print(f"✅ Vertex AI initialized for project: {vertex_ai_project_id} in {vertex_ai_location}")
except Exception as e:
    print(f"❌ Error initializing Vertex AI: {e}")
    pass


app = Flask(__name__)
CORS(app)


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
        "insights": {
            "type": "string",
            "description": "ユーザーの心理状態、葛藤、ニーズに関する400〜600字程度の統合的な分析レポート"
        }
    },
    "required": ["insights"]
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
    """トピックに基づき、初回の質問を生成する"""
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
    """以前の分析(insights)に基づき、深掘り質問を生成する"""
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


def generate_summary_with_gemini(swipes_text):
    """Geminiを使ってサマリー(insights)を生成する"""
    prompt = f"""
あなたは、ユーザーの感情の動きを分析するプロの臨床心理士です。
以下のユーザーとの会話履歴（質問と回答のペア、そしてためらい時間やスワイプ速度といったインタラクションデータ）を総合的に分析してください。

# 分析対象の会話履歴
{swipes_text}

# あなたのタスク
ユーザーの回答内容と言動（スワイプの速さ・ためらい）の両方から、ユーザーの現在の心理状態、内面的な葛藤、そして本人も気づいていないかもしれない「真の願い」や「潜在的なニーズ」について、深く、かつ共感的に分析してください。

# 分析のポイント
- **感情の一貫性と矛盾**: ユーザーの回答（Yes/No）と、その際の感情の現れ（ためらいが長い、即答するなど）は一致していますか？ もし不一致がある場合、それはどのような心理的な葛藤を示唆していますか？
- **核心となる問い**: どの質問に対して、ユーザーは最も感情的な反応（非常に長い/短い時間での反応）を示しましたか？ それがこのセッションの核心である可能性について考察してください。
- **潜在的なニーズの特定**: これまでの分析を踏まえ、このユーザーが本当に望んでいること、あるいは必要としているサポートは何だと考えられますか？
- **ためらい時間や速度の具体的な数値は出力に含めず**、それらのデータからあなたが読み取った「解釈」だけを、自然な文章で記述してください。
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

    if not all([question_id, answer]):
        return jsonify({'error': 'Missing required fields in swipe data'}), 400

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500

    try:
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        
        swipes_collection = session_doc_ref.collection('swipes')
        swipes_collection.add({
            'question_id': question_id,
            'question_ref': db_firestore.collection('users').document(user_id).collection('sessions').document(session_id).collection('questions').document(question_id),
            'answer': answer,
            'hesitation_time_sec': hesitation_time,
            'swipe_duration_ms': speed,
            'timestamp': firestore.SERVER_TIMESTAMP
        })
        
        return jsonify({'status': 'swipe_recorded'}), 200

    except Exception as e:
        print(f"Error recording swipe: {e}")
        return jsonify({'error': 'Failed to record swipe', 'details': str(e)}), 500


@app.route('/session/<string:session_id>/summary', methods=['GET'])
def get_summary(session_id):
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

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500

    session_doc_ref = None
    try:
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        
        swipes_query = session_doc_ref.collection('swipes').order_by('timestamp', direction=firestore.Query.ASCENDING).stream()

        swipes_text_list = []
        for swipe in swipes_query:
            swipe_data = swipe.to_dict()
            q_ref = swipe_data.get('question_ref')
            if q_ref:
                q_doc = q_ref.get()
                if q_doc.exists:
                    q_text = q_doc.to_dict().get('text', '不明な質問')
                    answer = swipe_data.get('answer', '不明な回答')
                    hesitation = swipe_data.get('hesitation_time_sec', 0)
                    duration = swipe_data.get('swipe_duration_ms', 0)
                    swipes_text_list.append(
                        f"Q: {q_text}\n"
                        f"A: {answer} (ためらい: {hesitation:.2f}秒, 速度: {duration}ms)"
                    )
        
        if not swipes_text_list:
            raise Exception("No swipes found for this session.")

        swipes_text = "\n".join(swipes_text_list)
        
        summary_data = generate_summary_with_gemini(swipes_text)
        
        session_doc = session_doc_ref.get()
        if not session_doc.exists:
             raise Exception("Session document not found after summary generation.")
        
        session_turn = session_doc.to_dict().get('turn', 1)

        session_doc_ref.update({
            'insights': summary_data.get('insights'),
            'status': 'completed',
            'updated_at': firestore.SERVER_TIMESTAMP,
        })
        
        summary_data['turn'] = session_turn
        return jsonify(summary_data)

    except Exception as e:
        print(f"Error getting summary: {e}")
        if session_doc_ref:
            try:
                session_doc_ref.update({'status': 'error', 'error_message': str(e)})
            except Exception as update_e:
                print(f"Failed to update session status to error: {update_e}")
        return jsonify({'error': 'Failed to get summary', 'details': str(e)}), 500


@app.route('/session/<string:session_id>/continue', methods=['POST'])
def continue_session(session_id):
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
    if not data or 'insights' not in data:
        return jsonify({'error': 'Insights are required'}), 400
    
    insights = data['insights']

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500

    try:
        questions = generate_follow_up_questions(insights=insights)
        if not questions or len(questions) < 1:
            raise Exception("AI failed to generate sufficient follow-up questions.")

        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        
        @firestore.transactional
        def update_turn_in_transaction(transaction, session_ref):
            snapshot = session_ref.get(transaction=transaction)
            if not snapshot.exists:
                raise Exception("Session not found in transaction")
            
            current_turn = snapshot.to_dict().get('turn', 1)
            new_turn = current_turn + 1
            
            transaction.update(session_ref, {
                'status': 'in_progress',
                'updated_at': firestore.SERVER_TIMESTAMP,
                'turn': new_turn
            })
            return new_turn

        transaction = db_firestore.transaction()
        new_turn = update_turn_in_transaction(transaction, session_doc_ref)

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
                    'order': start_order + i,
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