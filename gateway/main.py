import os
import firebase_admin
from firebase_admin import credentials, firestore, auth
from flask import Flask, request, jsonify, g # g をインポート
from flask_cors import CORS
import requests # HTTPリクエストを送信するために追加
import json # JSONを扱うために追加
import sqlite3 # sqlite3 をインポート
import uuid # uuid をインポート
import datetime # datetime をインポート


app = Flask(__name__)
CORS(app)
DATABASE = 'guchiswipe.db' # ユーザー提供のパス

# Firebase Admin SDKの初期化
db_firestore = None
try:
    cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if not cred_path:
        print("警告: 環境変数 GOOGLE_APPLICATION_CREDENTIALS が設定されていません。デフォルト認証を使用します。")
        cred = credentials.ApplicationDefault()
        firebase_admin.initialize_app(cred)
    else:
        cred = credentials.Certificate(cred_path)
        firebase_admin.initialize_app(cred)
    
    db_firestore = firestore.client()
    print("Firebase Admin SDKが正常に初期化され、Firestoreクライアントを取得しました。")
except Exception as e:
    print(f"Firebase Admin SDKの初期化またはFirestoreクライアントの取得に失敗しました: {e}")
    db_firestore = None # エラー時はNoneのまま

def get_db():
    db = getattr(g, '_database', None)
    if db is None:
        db = g._database = sqlite3.connect(DATABASE)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
    return db

# Gemma on Ollamaを呼び出す関数 (user_name引数を削除)
def generate_summary_with_ollama_gemma(swipes_text: str) -> dict:
    """OllamaでホストされているGemmaモデルを使って要約と分析を生成し、辞書で返す"""
    
    # このURLを、ご自身のOllama on Cloud RunのエンドポイントURLに置き換えてください
    OLLAMA_BASE_URL = os.getenv("OLLAMA_ENDPOINT_URL", "https://ollama-sample-1036638910637.us-central1.run.app")

    if "YOUR_OLLAMA_ENDPOINT_URL" in OLLAMA_BASE_URL:
        error_message = "（AI分析エラー: OLLAMA_ENDPOINT_URL環境変数が設定されていません）"
        print(error_message)
        return {"summary": error_message, "analysis": error_message}
    
    ollama_api_url = f"{OLLAMA_BASE_URL.rstrip('/')}/api/generate"

    prompt = f"""あなたはユーザーの心の動きを読み解く、鋭い洞察力を持つAIアナリストです。
        以下のセッションデータを分析し、指定されたフォーマットで厳密に出力してください。

        ---
        【セッションデータ】
        {swipes_text}
        ---

        【指示】
        1. まず、`===SUMMARY===` という区切り文字の後に、セッション全体の会話内容を3行程度で簡潔にまとめてください。
        2. 次に、`===ANALYSIS===` という区切り文字の後に、以下のルールに従って詳細なインタラクション分析を記述してください。
        - 「反応時間」と「スワイプ速度」という行動データに注目してください。
        - **重要:** 分析結果に具体的な数値（例: 2.10秒, 速度627）を直接含めないでください。
        - 代わりに、その数値が示す意味（例：「他の質問より少し時間をかけて」「特に力強く」など）を解釈して表現してください。
        - **最重要:** 分析レポートとして、客観的な視点で記述してください。ユーザー個人への呼びかけ（「あなた」「〇〇さん」など）は絶対に使用しないでください。

        【出力フォーマット】
        ===SUMMARY===
        ここに要約を記述
        ===ANALYSIS===
        ここにインタラクション分析を記述
        """

    payload = {
        "model": "gemma3:4B",  
        "prompt": prompt,
        "stream": False
    }

    try:
        response = requests.post(ollama_api_url, json=payload, timeout=90)
        response.raise_for_status()

        gemma_response_text = response.json().get("response", "").strip()
        
        summary = "要約の取得に失敗しました。"
        analysis = "分析の取得に失敗しました。"

        if "===ANALYSIS===" in gemma_response_text:
            parts = gemma_response_text.split("===ANALYSIS===", 1)
            analysis = parts[1].strip()
            if "===SUMMARY===" in parts[0]:
                summary = parts[0].split("===SUMMARY===", 1)[1].strip()
            else:
                summary = "（要約部分がありませんでした）"
        elif "===SUMMARY===" in gemma_response_text:
            summary = gemma_response_text.split("===SUMMARY===", 1)[1].strip()
            analysis = "（分析部分がありませんでした）"
        else:
            analysis = gemma_response_text if gemma_response_text else "分析結果が空でした。"

        return {"summary": summary, "analysis": analysis}

    except requests.exceptions.RequestException as e:
        print(f"Ollamaへのリクエスト中にエラーが発生しました: {e}")
        error_msg = f"（AI分析エラーが発生しました: {e}）"
        return {"summary": error_msg, "analysis": error_msg}
    except Exception as e:
        print(f"Ollamaでの要約生成中に予期せぬエラーが発生しました: {e}")
        error_msg = f"（AI分析中に予期せぬエラーが発生しました: {e}）"
        return {"summary": error_msg, "analysis": error_msg}


@app.teardown_appcontext
def close_connection(exception):
    db = getattr(g, '_database', None)
    if db is not None:
        db.close()

def init_db():
    with app.app_context():
        db = get_db()
        with app.open_resource('schema.sql', mode='r') as f:
            db.cursor().executescript(f.read())
        db.commit()
        print("SQLite Database initialized.")
        insert_initial_questions(db)

def insert_initial_questions(db):
    questions_data = [
        ('q1', '今日は気分が良いですか？', 1),
        ('q2', '何か楽しみな予定がありますか？', 2),
        ('q3', '少し疲れている感じがしますか？', 3),
        ('q4', '誰かに話を聞いてほしいことはありますか？', 4),
        ('q5', '新しいことに挑戦したい気持ちはありますか？', 5)
    ]
    cursor = db.cursor()
    try:
        cursor.executemany('INSERT OR IGNORE INTO questions (question_id, question_text, order_num) VALUES (?, ?, ?)', questions_data)
        db.commit()
        print(f"{cursor.rowcount} initial questions inserted into SQLite.")
    except sqlite3.Error as e:
        print(f"Error inserting initial questions into SQLite: {e}")


@app.route('/session/start', methods=['POST'])
def start_session():
    data = request.get_json()
    if not data or 'user_id' not in data:
        return jsonify({'error': 'Missing data: user_id is required'}), 400
    
    user_id = data['user_id']
    new_session_id = str(uuid.uuid4())
    db_sqlite = get_db()

    if db_firestore:
        try:
            session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(new_session_id)
            session_doc_ref.set({
                'createdAt': firestore.SERVER_TIMESTAMP,
                'status': 'in_progress',
                'sqlite_session_id': new_session_id
            })
            print(f"Firestore: Session started users/{user_id}/sessions/{new_session_id}")
        except Exception as e:
            print(f"Firestore error starting session: {e}")
    else:
        print("Warning: Firestore client not initialized. Skipping Firestore operation for session start.")

    try:
        cursor = db_sqlite.cursor()
        cursor.execute('INSERT INTO sessions (session_id, created_at) VALUES (?, ?)',
                       (new_session_id, datetime.datetime.now()))
        db_sqlite.commit()

        cursor.execute('SELECT question_id, question_text FROM questions ORDER BY order_num ASC LIMIT 1')
        first_question = cursor.fetchone()

        if first_question:
            return jsonify({
                'session_id': new_session_id,
                'question_id': first_question['question_id'],
                'question_text': first_question['question_text']
            }), 201
        else:
            return jsonify({'error': 'No questions available in SQLite'}), 500
    except sqlite3.Error as e:
        db_sqlite.rollback()
        return jsonify({'error': f"SQLite error: {str(e)}"}), 500

# /session/<session_id>/swipe エンドポイントの修正
@app.route('/session/<string:session_id>/swipe', methods=['POST'])
def swipe(session_id):
    data = request.get_json()
    # フロントエンドからのキー名'hesitationTime'に合わせる
    required_keys = ['question_id', 'answer', 'user_id', 'hesitationTime']
    if not data or not all(key in data for key in required_keys):
        return jsonify({'error': f'Missing data: {", ".join(required_keys)} are required'}), 400

    question_id = data['question_id']
    answer = data['answer']
    user_id = data['user_id']
    hesitation_time = data['hesitationTime']
    # 'speed'はフロントから送られていないので、デフォルト値または別の扱いにする
    speed = data.get('speed', 0.0) # speedキーがなくてもエラーにならないように

    if answer not in ['yes', 'no']:
        return jsonify({'error': 'Invalid answer. Must be "yes" or "no"'}), 400
    try:
        hesitation_time = float(hesitation_time)
        speed = float(speed)
    except ValueError:
        return jsonify({'error': 'Invalid hesitationTime or speed. Must be a number'}), 400

    db_sqlite = get_db()
    
    if db_firestore:
        try:
            session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
            question_text_cursor = db_sqlite.cursor()
            question_text_cursor.execute('SELECT question_text FROM questions WHERE question_id = ?', (question_id,))
            question_row = question_text_cursor.fetchone()
            question_text = question_row['question_text'] if question_row else "Unknown Question"

            swipe_ref = session_doc_ref.collection('swipes').document()
            swipe_ref.set({
                'questionId': question_id,
                'questionText': question_text,
                'answer': answer,
                'speed': speed, # speedも保存
                'hesitationTime': hesitation_time,
                'swipedAt': firestore.SERVER_TIMESTAMP
            })
            print(f"Firestore: Swipe recorded users/{user_id}/sessions/{session_id}/swipes/{swipe_ref.id}")
        except Exception as e:
            print(f"Firestore error recording swipe: {e}")
    else:
        print("Warning: Firestore client not initialized. Skipping Firestore operation for swipe.")
    
    try:
        cursor = db_sqlite.cursor()
        cursor.execute('SELECT 1 FROM sessions WHERE session_id = ?', (session_id,))
        if cursor.fetchone() is None:
            return jsonify({'error': 'SQLite: Session not found'}), 404

        cursor.execute('''
            INSERT INTO swipes (session_id, question_id, direction, speed, answered_at)
            VALUES (?, ?, ?, ?, ?)
        ''', (session_id, question_id, answer, speed, datetime.datetime.now()))
        db_sqlite.commit()

        cursor.execute('SELECT order_num FROM questions WHERE question_id = ?', (question_id,))
        current_question_data = cursor.fetchone()
        if not current_question_data:
            return jsonify({'error': 'SQLite: Invalid question_id'}), 404
        current_order_num = current_question_data['order_num']

        cursor.execute('''
            SELECT question_id, question_text FROM questions
            WHERE order_num > ? ORDER BY order_num ASC LIMIT 1
        ''', (current_order_num,))
        next_question = cursor.fetchone()

        if next_question:
            return jsonify({
                'next_question_id': next_question['question_id'],
                'next_question_text': next_question['question_text'] # ★★★ 'text' から 'question_text' に修正 ★★★
            }), 200
        else:
            if db_firestore:
                try:
                    session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
                    session_doc_ref.update({
                        'status': 'completed',
                        'completedAt': firestore.SERVER_TIMESTAMP
                    })
                    print(f"Firestore: Session status updated to completed for users/{user_id}/sessions/{session_id}")
                except Exception as e:
                    print(f"Firestore error updating session status to completed: {e}")
            
            return jsonify({'session_status': 'completed', 'message': 'All questions answered.'}), 200

    except sqlite3.Error as e:
        db_sqlite.rollback()
        return jsonify({'error': f"SQLite error: {str(e)}"}), 500
    except Exception as e:
        return jsonify({'error': f"An unexpected error occurred: {str(e)}"}), 500

  
@app.route('/session/<string:session_id>/summary', methods=['GET'])
def get_summary(session_id):
    user_id = request.args.get('user_id')

    if not user_id and db_firestore:
        return jsonify({'error': 'user_id is required for summary with Firestore'}), 400

    db_sqlite = get_db()
    summary_data_sqlite = {}
    try:
        cursor = db_sqlite.cursor()
        cursor.execute('SELECT 1 FROM sessions WHERE session_id = ?', (session_id,))
        if cursor.fetchone() is None:
            return jsonify({'error': 'SQLite: Session not found'}), 404

        cursor.execute('SELECT direction, speed FROM swipes WHERE session_id = ?', (session_id,))
        swipes_data_sqlite = cursor.fetchall()

        if not swipes_data_sqlite:
            return jsonify({'message': 'No swipes recorded for this session yet in SQLite.'}), 200

        yes_count = sum(1 for r in swipes_data_sqlite if r['direction'] == 'yes')
        no_count = sum(1 for r in swipes_data_sqlite if r['direction'] == 'no')
        speeds = [r['speed'] for r in swipes_data_sqlite]
        avg_speed = sum(speeds) / len(speeds) if speeds else 0

        summary_data_sqlite = {
            'session_id': session_id,
            'total_swipes': len(swipes_data_sqlite),
            'yes_count': yes_count,
            'no_count': no_count,
            'average_speed': round(avg_speed, 2),
        }

        if db_firestore and user_id:
            try:
                swipes_for_prompt_ref = db_firestore.collection('users', user_id, 'sessions', session_id, 'swipes').order_by('swipedAt').stream()
                
                swipes_list_for_prompt = []
                for swipe_doc in swipes_for_prompt_ref:
                    swipe_data = swipe_doc.to_dict()
                    question = swipe_data.get('questionText', '不明な質問')
                    answer_direction = swipe_data.get('answer', '不明')
                    answer_text = "はい" if answer_direction == 'yes' else "いいえ"
                    
                    speed = swipe_data.get('speed', 0.0)
                    hesitation_time = swipe_data.get('hesitationTime', 0.0)
                    
                    swipes_list_for_prompt.append(
                        f"Q: {question}\n"
                        f"A: {answer_text} (反応時間: {hesitation_time:.2f}秒, スワイプ速度: {abs(speed):.0f})"
                    )

                swipes_text = "\n\n".join(swipes_list_for_prompt)
                
                gemma_results = {"summary": "", "analysis": ""}
                if swipes_text:
                    # user_nameを渡さないように呼び出しを修正
                    gemma_results = generate_summary_with_ollama_gemma(swipes_text)
                
                session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
                session_doc_snapshot = session_doc_ref.get()
                if session_doc_snapshot.exists:
                    summary_update_data = {
                        'yes_count': yes_count,
                        'no_count': no_count,
                        'average_speed': round(avg_speed, 2),
                        'total_swipes': len(swipes_data_sqlite),
                        'gemma_summary': gemma_results.get('summary')
                    }
                    
                    update_data = {
                        'status': 'completed',
                        'summary': summary_update_data,
                        'gemma_interaction_analysis': gemma_results.get('analysis')
                    }

                    if 'completedAt' not in session_doc_snapshot.to_dict():
                         update_data['completedAt'] = firestore.SERVER_TIMESTAMP

                    session_doc_ref.update(update_data)
                    print(f"Firestore: Session summary updated for users/{user_id}/sessions/{session_id}")
                else:
                    print(f"Warning: Firestore session document not found for summary update: users/{user_id}/sessions/{session_id}")
            except Exception as e:
                print(f"Firestore error updating session summary: {e}")
        elif not user_id and db_firestore:
             print("Warning: user_id not provided, Firestore summary update skipped.")
        elif not db_firestore:
            print("Warning: Firestore client not initialized. Skipping Firestore summary update.")

        return jsonify({
            **summary_data_sqlite,
            'message': 'Thank you for sharing your feelings!'
        }), 200

    except sqlite3.Error as e:
        return jsonify({'error': f"SQLite error: {str(e)}"}), 500
    except Exception as e:
        return jsonify({'error': f"An unexpected error occurred: {str(e)}"}), 500

if __name__ == '__main__':
    with app.app_context():
        init_db()
    app.run(debug=True, host='0.0.0.0', port=8080)