import firebase_admin
from firebase_admin import credentials, firestore, auth
from flask import Flask, request, jsonify
from flask_cors import CORS

import os
import json
import re
import traceback

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
    app_instance = firebase_admin.get_app()
    project_id = app_instance.project_id
    print(f"✅ Firebase Admin SDK initialized for project: {project_id}")

    # Vertex AIを初期化
    vertex_ai_region = os.getenv('GCP_VERTEX_AI_REGION', 'us-central1')
    vertexai.init(project=project_id, location=vertex_ai_region)
    print(f"✅ Vertex AI initialized for project: {project_id} in {vertex_ai_region}")

except Exception as e:
    db_firestore = None
    print(f"❌ Error during initialization: {e}")
    traceback.print_exc()
    # 本番環境で初期化に失敗したら、起動を中止してログにエラーを残します
    if 'K_SERVICE' in os.environ:
        raise

app = Flask(__name__)
# CORS設定: Firebase Hostingからのリクエストを明示的に許可
prod_origin = "https://guchi-app-flutter.web.app"

# 'K_SERVICE'環境変数はCloud Runで設定されるため、その有無で環境を判定
if 'K_SERVICE' in os.environ:
    # 本番環境では、デプロイされたWebアプリからのリクエストのみを許可
    origins = [prod_origin]
else:
    # ローカル開発環境では、本番サイトとローカルからのリクエストの両方を許可
    # Flutter Webはデバッグ時にランダムなポートを使用するため、正規表現で対応
    origins = [
        prod_origin,
        re.compile(r"http://localhost:.*"),
        re.compile(r"http://127.0.0.1:.*"),
    ]

# CORS設定: 上記で決定した許可リストに基づいてリクエストを許可
CORS(app, resources={r"/*": {"origins": origins}})

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


GRAPH_ANALYSIS_PROMPT_TEMPLATE = """
あなたはデータサイエンティストであり、臨床心理士でもあります。
これから渡すテキストは、あるユーザーの複数回のカウンセリングセッション（ココロヒモトク）の記録です。
この記録全体を分析し、ユーザーの心理状態の核となる要素（感情、悩み、トピック、重要なキーワード）を抽出し、それらの関連性を表現するグラフデータを生成してください。

出力は、以下の仕様に厳密に従ったJSON形式のみとしてください。説明や前置きは一切不要です。

【出力JSONの仕様】
{
  "nodes": [
    {
      "id": "string",  // ノードの名称（感情、トピック、キーワードなど）
      "type": "string",  // ノードの種類 ('emotion', 'topic', 'keyword', 'issue')
      "size": "integer" // ノードの重要度や出現頻度。10から30の範囲の整数。
    }
  ],
  "edges": [
    {
      "source": "string", // エッジの始点となるノードのid
      "target": "string", // エッジの終点となるノードのid
      "weight": "integer"  // 関連性の強さ。1から10の範囲の整数。
    }
  ]
}

【分析のヒント】
- 複数のセッションで繰り返し出現する感情や単語は重要です。sizeを大きく設定してください。
- セッションの主題(topic)は中心的なノードとなる可能性があります。
- AIの分析結果内（「気になった受け答え」や「根本的な問題」など）で言及されている要素は重要です。
- 関連性の強さ(weight)は、単語が同じ文脈で出現する頻度や、因果関係が示唆されている度合いを考慮してください。
- ノードの数は10個から20個程度に収め、ユーザーの心理状態の全体像が把握できるように要約してください。
- `type` は 'emotion' (感情: 不安, 喜び), 'topic' (主題: 仕事, 家族), 'keyword' (その他キーワード: 自己肯定感, コミュニケーション), 'issue' (課題: 完璧主義, 依存) のいずれかに分類してください。

【セッション記録】
"""

CHAT_PROMPT_TEMPLATE = """
あなたは、ユーザーの心理分析の専門家であり、共感力と洞察力に優れたカウンセラーです。
ユーザーは、あなたが行った過去のセッション分析（思考の関連性を可視化したグラフ）を見ながら、自分の内面について探求しようとしています。

以下の情報を元に、ユーザーからの質問やコメントに誠実に、そして洞察に満ちた応答を返してください。

【ユーザーのこれまでのセッション記録の要約】
{session_summary}

【これまでのチャット履歴】
{chat_history}

【ユーザーからの新しいメッセージ】
{user_message}

【あなたの役割と応答の指針】
- ユーザーの言葉を肯定的に受け止め、共感を示してください。
- セッション記録の要約から具体的なキーワードや関連性を引用し、ユーザーの気づきを促してください。（例：「『仕事の悩み』と『自己肯定感』が繋がっているようですが、何か思い当たることはありますか？」）
- 決めつけたり、断定的な言い方は避けてください。あくまでユーザー自身が答えを見つける手助けをする、という姿勢を保ってください。
- 応答は、簡潔かつ分かりやすい言葉で、2〜3文程度でまとめてください。
- あなた自身のことを「AI」や「モデル」とは言わず、一貫してカウンセラーとして振る舞ってください。

応答はテキストのみで、前置きや説明は一切不要です。
"""


# ===== Gemini 呼び出しヘルパー関数 (リトライ機能付き) =====
@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(3))
def _call_gemini_with_schema(prompt: str, schema: dict, model_name: str) -> dict:
    """指定されたモデルを使い、構造化出力でGeminiを呼び出し、JSONを返す。"""
    model = GenerativeModel(model_name)
    
    attempt_num = _call_gemini_with_schema.retry.statistics.get('attempt_number', 1)
    print(f"--- Calling Gemini ({model_name}) with schema (Attempt: {attempt_num}) ---")

    response_text = ""
    try:
        response = model.generate_content(
            prompt,
            generation_config=GenerationConfig(
                response_mime_type="application/json",
                response_schema=schema,
            ),
        )
        response_text = response.text
        
        json_start = response_text.find('{')
        json_end = response_text.rfind('}')
        if json_start != -1 and json_end != -1 and json_end > json_start:
            cleaned_text = response_text[json_start:json_end+1]
            return json.loads(cleaned_text)
        
        return json.loads(response_text)

    except Exception as e:
        print(f"Error on attempt {attempt_num} with model {model_name}: {e}")
        print(f"--- Gemini Response Text on Error ---\n{response_text if response_text else 'Response text was empty.'}\n------------------------------------")
        traceback.print_exc()
        raise

# ===== Gemini 呼び出しメイン関数 =====
def generate_initial_questions(topic):
    prompt = f"""
あなたは、ユーザーの悩みに寄り添う、思慮深いカウンセラーです。
ユーザーが選択したトピック「{topic}」について、対話を深めるための「はい」か「いいえ」で答えられる質問を5つ生成してください。
質問は、前の質問からの流れを汲み、徐々に核心に迫るように構成してください。
"""
    try:
        flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
        data = _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA, model_name=flash_model)
        return data.get("questions", [])
    except Exception as e:
        print(f"Failed to generate initial questions after retries: {e}")
        traceback.print_exc()
        return [{"question_text": q} for q in [
            "最近、特にストレスを感じることはありますか？", "何か新しい挑戦をしたいと思っていますか？", "自分の時間をもっと大切にしたいですか？",
            "人間関係で何か改善したい点はありますか？", "今の生活に満足していますか？"
        ]]

def generate_follow_up_questions(insights):
    """
    【修正1: 予防的なバグ修正】
    この関数では、AIを呼び出す際に必要なモデル名の指定が抜けていました。
    将来の「深掘り」機能でエラーが発生しないように、ここで修正します。
    """
    prompt = f"""
あなたは、ユーザーの悩みに寄り添う、思慮深いカウンセラーです。
ユーザーとのこれまでの対話から、あなたは以下のような深い洞察を得ました。

# あなたの分析(洞察)
{insights}

この洞察をさらに深め、ユーザーが自身の気持ちをより明確に理解できるよう、核心に迫る「はい」か「いいえ」で答えられる質問を新たに5つ生成してください。
質問は、分析結果から浮かび上がったテーマや葛藤に直接関連するものにしてください。
"""
    flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
    data = _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA, model_name=flash_model)
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
    flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-2.5-flash-preview-05-20')
    return _call_gemini_with_schema(prompt, SUMMARY_SCHEMA, model_name=flash_model)

def generate_graph_data(all_insights_text):
    """全セッションのインサイトからグラフデータを生成する"""
    prompt = GRAPH_ANALYSIS_PROMPT_TEMPLATE + all_insights_text
    try:
        # グラフ生成には、ユーザー指定の高性能なProモデルを使用
        pro_model = os.getenv('GEMINI_PRO_NAME', 'gemini-2.5-pro-preview-05-06')
        data = _call_gemini_with_schema(prompt, GRAPH_SCHEMA, model_name=pro_model)
        return data
    except Exception as e:
        print(f"Failed to generate graph data after retries: {e}")
        traceback.print_exc()
        # On failure, return an empty graph structure to avoid frontend errors.
        return {"nodes": [], "edges": []}

def generate_chat_response(session_summary, chat_history, user_message):
    """チャットの応答を生成する"""
    history_str = "\n".join([f"{msg['author']}: {msg['text']}" for msg in chat_history])
    
    prompt = CHAT_PROMPT_TEMPLATE.format(
        session_summary=session_summary,
        chat_history=history_str,
        user_message=user_message
    )
    
    try:
        flash_model = os.getenv('GEMINI_PRO_NAME', 'gemini-2.5-pro-preview-05-20')
        model = GenerativeModel(flash_model)
        
        print(f"--- Calling Gemini ({flash_model}) for chat ---")
        response = model.generate_content(prompt)
        
        return response.text.strip()
        
    except Exception as e:
        print(f"Failed to generate chat response: {e}")
        traceback.print_exc()
        return "申し訳ありません、現在応答できません。しばらくしてからもう一度お試しください。"



# ===== API Routes =====
@app.route('/session/start', methods=['POST'])
def start_session():
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token, clock_skew_seconds=15)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in start_session: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Token verification failed in start_session: {e}")
        traceback.print_exc()
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
        traceback.print_exc()
        return jsonify({'error': 'Failed to start session', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/swipe', methods=['POST'])
def record_swipe(session_id):
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401

        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token, clock_skew_seconds=15)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in record_swipe: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Token verification failed in record_swipe: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Token verification failed', 'details': str(e)}), 500

    data = request.get_json()
    if not data: return jsonify({'error': 'Request body is missing'}), 400

    question_id = data.get('question_id')
    answer = data.get('answer') 
    hesitation_time = data.get('hesitation_time')
    speed = data.get('speed')
    turn = data.get('turn')

    if not all([question_id, turn is not None]) or not isinstance(answer, bool):
        return jsonify({'error': 'Missing or invalid type for required fields in swipe data'}), 400

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
        traceback.print_exc()
        return jsonify({'error': 'Failed to record swipe', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/summary', methods=['POST'])
def post_summary(session_id):
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401

        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token, clock_skew_seconds=15)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in post_summary: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Token verification failed in post_summary: {e}")
        traceback.print_exc()
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
            answer_bool = swipe.get('answer')
            if not isinstance(answer_bool, bool):
                continue

            answer_text = "はい" if answer_bool else "いいえ"
            
            hesitation = swipe.get('hesitation_time', 0.0)
            if not isinstance(hesitation, (int, float)):
                hesitation = 0.0

            hesitation_comment = ""
            if hesitation >= 3.0:
                hesitation_comment = f"（回答に{hesitation:.1f}秒かかっており、特に迷いが見られました）"

            swipes_text_list.append(f"Q: {q_text}\nA: {answer_text} {hesitation_comment}")
            
        if not swipes_text_list:
            return jsonify({'error': 'No valid swipe data received to generate summary.'}), 400

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
        traceback.print_exc()
        return jsonify({'error': 'Failed to generate summary', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/continue', methods=['POST'])
def continue_session(session_id):
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token, clock_skew_seconds=15)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in continue_session: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Token verification failed in continue_session: {e}")
        traceback.print_exc()
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
        traceback.print_exc()
        return jsonify({'error': 'Failed to continue session', 'details': str(e)}), 500

def _get_all_insights_as_text(user_id: str) -> str:
    """指定されたユーザーの全セッションのインサイトを1つのテキストに結合する。"""
    if not db_firestore:
        return ""
    
    sessions_ref = db_firestore.collection('users').document(user_id).collection('sessions')
    sessions_query = sessions_ref.order_by('created_at', direction=firestore.Query.DESCENDING).limit(20)
    sessions = list(sessions_query.stream())
    sessions.reverse()

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
            print(f"Skipping potentially corrupted session {session.id} for chat context due to error: {inner_e}")
            continue
    
    return "".join(all_insights)


@app.route('/analysis/chat', methods=['POST'])
def post_chat_message():
    # Auth check
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token, clock_skew_seconds=15)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        return jsonify({'error': 'Token verification failed', 'details': str(e)}), 500
        
    data = request.get_json()
    if not data:
        return jsonify({'error': 'Request body is missing'}), 400
        
    chat_history = data.get('chat_history', [])
    user_message = data.get('message', '')
    
    if not user_message:
        return jsonify({'error': 'message is required'}), 400
        
    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500
    
    try:
        session_summary = _get_all_insights_as_text(user_id)
        
        if not session_summary:
            ai_response = "こんにちは。分析できるセッション履歴がまだないようです。まずはセッションを完了して、ご自身の内面を探る旅を始めてみましょう。"
        else:
            ai_response = generate_chat_response(session_summary, chat_history, user_message)
            
        return jsonify({'response': ai_response})
        
    except Exception as e:
        print(f"Error in post_chat_message: {e}")
        traceback.print_exc()
        return jsonify({"error": "An internal error occurred while processing the chat message.", "details": str(e)}), 500


#
# ===== ここからが完全に書き直された、新しいコードです =====
#
@app.route('/analysis/graph', methods=['GET'])
def get_analysis_graph():
    """
    【最終・完全修正】
    AIが生成したデータを、フロントエンドに送る前に徹底的に検証・洗浄（サニタイズ）します。
    これにより、データの不整合が原因でフロントエンドがクラッシュするのを完全に防ぎます。
    """
    # 1. 認証 (変更なし)
    try:
        auth_header = request.headers.get('Authorization', '')
        if not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Authorization token is missing or invalid'}), 401
        
        id_token = auth_header.split('Bearer ')[1]
        decoded_token = auth.verify_id_token(id_token, clock_skew_seconds=15)
        user_id = decoded_token['uid']
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        return jsonify({'error': 'Token verification failed', 'details': str(e)}), 500

    if not db_firestore: return jsonify({'error': 'Firestore not available'}), 500
    
    try:
        # 2. Firestoreからセッションデータを取得 (変更なし)
        sessions_ref = db_firestore.collection('users').document(user_id).collection('sessions')
        sessions_query = sessions_ref.order_by('created_at', direction=firestore.Query.DESCENDING).limit(20)
        sessions = list(sessions_query.stream())
        sessions.reverse()

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
                print(f"Skipping potentially corrupted session {session.id} due to error: {inner_e}")
                continue

        if not all_insights:
            return jsonify({"nodes": [], "edges": []})

        all_insights_text = "".join(all_insights)
        
        # 3. AIを呼び出してグラフデータを生成 (変更なし)
        raw_graph_data = generate_graph_data(all_insights_text)
        
        # 4. 【最重要】AIが生成したデータを徹底的に洗浄・再構築する
        sanitized_nodes = []
        nodes_from_ai = raw_graph_data.get('nodes', [])
        if isinstance(nodes_from_ai, list):
            for node in nodes_from_ai:
                if not isinstance(node, dict) or 'id' not in node:
                    continue # 不正な形式のノードは無視
                try:
                    # 'size'をnull/float/strでも安全に整数に変換
                    size = int(float(node.get('size', 10) or 10))
                except (ValueError, TypeError):
                    size = 10 # 変換失敗時のデフォルト値
                
                sanitized_nodes.append({
                    'id': node['id'],
                    'type': node.get('type', 'keyword'),
                    'size': size
                })

        valid_node_ids = {node['id'] for node in sanitized_nodes}
        
        sanitized_edges = []
        edges_from_ai = raw_graph_data.get('edges', [])
        if isinstance(edges_from_ai, list):
            for edge in edges_from_ai:
                if not isinstance(edge, dict):
                    continue # 不正な形式のエッジは無視
                
                source = edge.get('source')
                target = edge.get('target')

                # 参照整合性チェック：始点・終点が有効なノードリストに存在するか
                if source in valid_node_ids and target in valid_node_ids:
                    try:
                        # 'weight'をnull/float/strでも安全に整数に変換
                        weight = int(float(edge.get('weight', 1) or 1))
                    except (ValueError, TypeError):
                        weight = 1 # 変換失敗時のデフォルト値
                    
                    sanitized_edges.append({
                        'source': source,
                        'target': target,
                        'weight': weight
                    })

        final_graph_data = {
            "nodes": sanitized_nodes,
            "edges": sanitized_edges
        }

        # 5. 完全に安全になったデータをフロントエンドに送信
        print("--- Final Graph Data Sent to Frontend ---")
        print(json.dumps(final_graph_data, indent=2, ensure_ascii=False))
        print("-----------------------------------------")

        return jsonify(final_graph_data)

    except Exception as e:
        print(f"Error in get_analysis_graph: {e}")
        traceback.print_exc()
        return jsonify({"error": "An internal error occurred creating the graph.", "details": str(e)}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)