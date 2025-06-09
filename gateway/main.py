import os
import firebase_admin
from firebase_admin import credentials, firestore, auth
from flask import Flask, request, jsonify
from flask_cors import CORS
import json
import re
from dotenv import load_dotenv
from pathlib import Path
from tenacity import retry, stop_after_attempt, wait_exponential # Tenacityをインポート

import vertexai
from vertexai.generative_models import GenerativeModel
from google.oauth2 import service_account

# .envファイルのパスを明示的に指定して読み込む
dotenv_path = Path(__file__).parent / '.env'
load_dotenv(dotenv_path=dotenv_path)


# --- Firebase Admin SDKの初期化 ---
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


# --- Vertex AIの初期化 ---
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

# ===== プロンプト定義 =====
SUMMARY_PROMPT = """
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

# 制約条件
- 分析結果は、**「insights」**というキーを持つJSON形式で、JSONオブジェクトのみを出力してください。
- **ためらい時間や速度の具体的な数値は出力に含めず**、それらのデータからあなたが読み取った「解釈」だけを、自然な文章で記述してください。
- 全体で400〜600字程度の、読み応えのある一つの分析レポートとしてまとめてください。
- 説明文や ```json ``` は絶対に含めないでください。
{{
  "insights": "（ここに統合された分析レポートを記述）"
}}
"""

def _call_gemini_for_questions(prompt):
    """[Helper] Geminiを呼び出し、質問リストのJSONを解析して返す共通関数"""
    model = GenerativeModel(os.getenv('GEMINI_FLASH_NAME'))
    try:
        response = model.generate_content(prompt)
        match = re.search(r'\{.*\}', response.text, re.DOTALL)
        if not match:
            raise ValueError("Gemini response did not contain valid JSON.")
        
        json_text = match.group(0)
        questions_data = json.loads(json_text)
        
        if 'questions' not in questions_data or not isinstance(questions_data['questions'], list):
            raise ValueError("JSON from Gemini is missing 'questions' list.")
            
        return questions_data['questions']
    except Exception as e:
        print(f"Error calling Gemini for question generation: {e}")
        raise

def generate_initial_questions(topic):
    """トピックに基づき、初回の質問を生成する"""
    prompt = f"""
あなたは、ユーザーの悩みに寄り添う、思慮深いカウンセラーです。
ユーザーが選択したトピック「{topic}」について、対話を深めるための「はい」か「いいえ」で答えられる質問を5つ生成してください。
質問は、前の質問からの流れを汲み、徐々に核心に迫るように構成してください。

# 制約条件
- 必ず5つの質問を生成してください。
- 各質問は、必ず「はい」か「いいえ」で回答できる形式にしてください。
- 回答は、以下のJSON形式で、JSONオブジェクトのみを出力してください。説明文や```json ```は不要です。
{{
  "questions": [
    {{"question_text": "ここに1つ目の質問"}},
    {{"question_text": "ここに2つ目の質問"}},
    {{"question_text": "ここに3つ目の質問"}},
    {{"question_text": "ここに4つ目の質問"}},
    {{"question_text": "ここに5つ目の質問"}}
  ]
}}
"""
    return _call_gemini_for_questions(prompt)

def generate_follow_up_questions(insights):
    """以前の分析(insights)に基づき、深掘り質問を生成する"""
    prompt = f"""
あなたは、ユーザーの悩みに寄り添う、思慮深いカウンセラーです。
ユーザーとのこれまでの対話から、あなたは以下のような深い洞察を得ました。

# あなたの分析(洞察)
{insights}

この洞察をさらに深め、ユーザーが自身の気持ちをより明確に理解できるよう、核心に迫る「はい」か「いいえ」で答えられる質問を新たに5つ生成してください。
質問は、分析結果から浮かび上がったテーマや葛藤に直接関連するものにしてください。

# 制約条件
- 必ず5つの質問を生成してください。
- 各質問は、必ず「はい」か「いいえ」で回答できる形式にしてください。
- 回答は、以下のJSON形式で、JSONオブジェクトのみを出力してください。説明文や```json ```は不要です。
{{
  "questions": [
    {{"question_text": "ここに1つ目の質問"}},
    {{"question_text": "ここに2つ目の質問"}},
    {{"question_text": "ここに3つ目の質問"}},
    {{"question_text": "ここに4つ目の質問"}},
    {{"question_text": "ここに5つ目の質問"}}
  ]
}}
"""
    return _call_gemini_for_questions(prompt)

@retry(
    wait=wait_exponential(multiplier=1, min=2, max=10), # 待機時間: 2秒, 4秒, 8秒...
    stop=stop_after_attempt(3), # 最大3回試行
    reraise=True # 3回失敗したら最終的なエラーを発生させる
)
def generate_summary_with_gemini_with_retry(swipes_text):
    """[リトライ機能付き] Geminiを使ってサマリー(insights)を生成する"""
    model_name = os.getenv('GEMINI_FLASH_NAME')
    model = GenerativeModel(model_name)
    
    prompt = SUMMARY_PROMPT.format(swipes_text=swipes_text)
    
    attempt_num = generate_summary_with_gemini_with_retry.retry.statistics.get('attempt_number', 1)
    print(f"--- Calling Gemini for summary (Attempt: {attempt_num}) ---")

    try:
        response = model.generate_content(prompt)
        text_to_parse = response.text
        match = re.search(r'```json\s*(\{.*?\})\s*```', text_to_parse, re.DOTALL)
        if match:
            json_text = match.group(1)
        else:
            match = re.search(r'\{.*\}', text_to_parse, re.DOTALL)
            if match:
                json_text = match.group(0)
            else:
                raise ValueError(f"Gemini response did not contain valid JSON object: {text_to_parse}")

        cleaned_json_text = ''.join(c for c in json_text if c.isprintable() or c in '\n\r\t')
        return json.loads(cleaned_json_text)

    except Exception as e:
        print(f"Error calling Gemini for summary generation on attempt {attempt_num}: {e}")
        raise # リトライのために例外を再送出

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
            'turn': 1, # ★ ターン数を初期化
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
        
         # ★ 新しいリトライ機能付き関数を呼び出す
        summary_data = generate_summary_with_gemini_with_retry(swipes_text)
        
        session_doc = session_doc_ref.get()
        if not session_doc.exists:
             raise Exception("Session document not found after summary generation.")
        
        session_turn = session_doc.to_dict().get('turn', 1)

        session_doc_ref.update({
            'insights': summary_data.get('insights'), # ★ 新しい分析結果を保存
            'status': 'completed',
            'updated_at': firestore.SERVER_TIMESTAMP,
        })
        
        summary_data['turn'] = session_turn # ★ ターン数をレスポンスに追加
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
        
        # トランザクションで安全にターン数を更新
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
        update_turn_in_transaction(transaction, session_doc_ref)

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
            'questions': question_docs_for_frontend
        }), 200

    except Exception as e:
        print(f"Error in continue_session: {e}")
        return jsonify({'error': 'Failed to continue session', 'details': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)