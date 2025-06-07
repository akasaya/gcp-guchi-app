    DROP TABLE IF EXISTS sessions;
    DROP TABLE IF EXISTS questions;
    DROP TABLE IF EXISTS swipes;

    CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        user_id TEXT,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
    );

    CREATE TABLE questions (
        question_id TEXT PRIMARY KEY,
        question_text TEXT NOT NULL,
        order_num INTEGER UNIQUE -- 質問の順番を管理
    );

    CREATE TABLE swipes (
        swipe_id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        question_id TEXT NOT NULL,
        direction TEXT NOT NULL, -- 'yes' or 'no'
        speed REAL NOT NULL,
        answered_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id),
        FOREIGN KEY (question_id) REFERENCES questions (question_id)
    );