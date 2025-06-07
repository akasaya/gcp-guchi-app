import datetime # datetime モジュールをインポート
import sqlite3
import uuid
from flask import Flask, jsonify, request, g # g をインポート
from flask_cors import CORS
import firebase_admin
from firebase_admin import credentials, firestore
import os

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
    
    user_id = data['user_id'] # フロントエンドからFirebase UIDを受け取る
    new_session_id = str(uuid.uuid4())
    db_sqlite = get_db()

    # Firestoreにセッション開始情報を保存
    if db_firestore:
        try:
            session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(new_session_id)
            session_doc_ref.set({
                'createdAt': firestore.SERVER_TIMESTAMP,
                'status': 'in_progress',
                'sqlite_session_id': new_session_id # 参考情報として
            })
            print(f"Firestore: Session started users/{user_id}/sessions/{new_session_id}")
        except Exception as e:
            print(f"Firestore error starting session: {e}")
            # FirestoreエラーでもSQLite処理は続行
    else:
        print("Warning: Firestore client not initialized. Skipping Firestore operation for session start.")

    try:
        cursor = db_sqlite.cursor()
        # user_idもSQLiteのsessionsテーブルに保存する場合 (スキーマにuser_idカラムが必要)
        # cursor.execute('INSERT INTO sessions (session_id, user_id, created_at) VALUES (?, ?, ?)',
        #                (new_session_id, user_id, datetime.datetime.now()))
        # MVPのsessionsテーブルにはuser_idがないので、以下のように元の形を維持
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

@app.route('/session/<string:session_id>/swipe', methods=['POST'])
def swipe(session_id):
    data = request.get_json()
    # キーを 'answer' に統一 (以前の 'direction' から変更)
    if not data or 'question_id' not in data or 'answer' not in data or 'speed' not in data or 'user_id' not in data:
        return jsonify({'error': 'Missing data: question_id, answer, speed, and user_id are required'}), 400

    question_id = data['question_id']
    answer = data['answer'] # 'yes' or 'no'
    speed = data['speed']
    user_id = data['user_id'] # フロントエンドからFirebase UID

    if answer not in ['yes', 'no']:
        return jsonify({'error': 'Invalid answer. Must be "yes" or "no"'}), 400
    try:
        speed = float(speed)
    except ValueError:
        return jsonify({'error': 'Invalid speed. Must be a number'}), 400

    db_sqlite = get_db()
    
    # Firestoreにスワイプ情報を保存
    if db_firestore:
        try:
            session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
            # SQLiteから質問文を取得
            question_text_cursor = db_sqlite.cursor()
            question_text_cursor.execute('SELECT question_text FROM questions WHERE question_id = ?', (question_id,))
            question_row = question_text_cursor.fetchone()
            question_text = question_row['question_text'] if question_row else "Unknown Question"

            swipe_ref = session_doc_ref.collection('swipes').document() # 自動ID
            swipe_ref.set({
                'questionId': question_id,
                'questionText': question_text,
                'answer': answer, # 'answer' で保存
                'speed': speed,
                'swipedAt': firestore.SERVER_TIMESTAMP
            })
            print(f"Firestore: Swipe recorded users/{user_id}/sessions/{session_id}/swipes/{swipe_ref.id}")
        except Exception as e:
            print(f"Firestore error recording swipe: {e}")
            # FirestoreエラーでもSQLite処理は続行
    else:
        print("Warning: Firestore client not initialized. Skipping Firestore operation for swipe.")

    try:
        cursor = db_sqlite.cursor()
        cursor.execute('SELECT 1 FROM sessions WHERE session_id = ?', (session_id,))
        if cursor.fetchone() is None:
            return jsonify({'error': 'SQLite: Session not found'}), 404

        # SQLiteには 'direction' というカラム名で保存している場合、合わせる
        # ここでは 'answer' をそのまま 'direction' カラムに保存すると仮定
        cursor.execute('''
            INSERT INTO swipes (session_id, question_id, direction, speed, answered_at)
            VALUES (?, ?, ?, ?, ?)
        ''', (session_id, question_id, answer, speed, datetime.datetime.now())) # 'answer' を 'direction' カラムに
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
                'next_question_text': next_question['question_text']
            }), 200
        else:
            # セッション完了時、Firestoreのセッションステータスも更新
            if db_firestore:
                try:
                    session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
                    session_doc_ref.update({
                        'status': 'completed',
                        'completedAt': firestore.SERVER_TIMESTAMP 
                        # サマリー情報は /summary エンドポイントで更新するため、ここではステータスのみ
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
    user_id = request.args.get('user_id') # クエリパラメータから user_id を取得

    # user_id がない場合は Firestore 関連の処理をスキップ (もしくはエラー)
    if not user_id and db_firestore: # Firestoreを使うのにuser_idがないのは問題
        print("Warning: user_id not provided for summary, but Firestore is active. Skipping Firestore summary update.")
        # return jsonify({'error': 'user_id is required for summary with Firestore'}), 400

    db_sqlite = get_db()
    summary_data_sqlite = {}
    try:
        cursor = db_sqlite.cursor()
        cursor.execute('SELECT 1 FROM sessions WHERE session_id = ?', (session_id,))
        if cursor.fetchone() is None:
            return jsonify({'error': 'SQLite: Session not found'}), 404

        cursor.execute('''
            SELECT direction, speed FROM swipes WHERE session_id = ?
        ''', (session_id,))
        swipes_data = cursor.fetchall()

        if not swipes_data:
            return jsonify({'message': 'No swipes recorded for this session yet in SQLite.'}), 200

        yes_count = sum(1 for r in swipes_data if r['direction'] == 'yes')
        no_count = sum(1 for r in swipes_data if r['direction'] == 'no')
        speeds = [r['speed'] for r in swipes_data]
        avg_speed = sum(speeds) / len(speeds) if speeds else 0

        summary_data_sqlite = {
            'session_id': session_id,
            'total_swipes': len(swipes_data),
            'yes_count': yes_count,
            'no_count': no_count,
            'average_speed': round(avg_speed, 2),
        }

        # Firestoreのセッションサマリーを更新
        if db_firestore and user_id:
            try:
                session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
                session_doc_snapshot = session_doc_ref.get()
                if session_doc_snapshot.exists:
                    update_data = {
                        'status': 'completed', # 再確認
                        'summary': { # summary オブジェクトとして格納
                            'yes_count': yes_count,
                            'no_count': no_count,
                            'average_speed': round(avg_speed, 2),
                            'total_swipes': len(swipes_data)
                        }
                    }
                    # completedAt は swipe エンドポイントで全問回答時に設定される想定だが、なければここで設定も可
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
            **summary_data_sqlite, # SQLiteのサマリーを展開
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