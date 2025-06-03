# Pythonの公式イメージをベースとして使用
FROM python:3.11.6

# 環境変数設定
# PYTHONUNBUFFERED: Pythonの標準出力/エラー出力をバッファリングせずに直接表示
ENV PYTHONUNBUFFERED True
# PORT: Cloud Runがリッスンするポート (デフォルトは8080)
ENV PORT 8080

# アプリケーションコードを配置するディレクトリを作成
WORKDIR /app

# 依存関係ファイルをコピーし、インストール
# まず requirements.txt だけをコピーして先にインストールすることで、
# アプリケーションコードの変更時に毎回ライブラリを再インストールするのを防ぎ、ビルド時間を短縮できます。
COPY requirements.txt requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# アプリケーションのソースコードをコピー
COPY . .

# Gunicornを本番環境用のWSGIサーバーとして使用
# main:app は、main.py ファイル内の app という名前のFlaskインスタンスを指定
# ワーカー数は環境に応じて調整してください (例: (2 * CPU数) + 1)
CMD exec gunicorn --bind :${PORT} --workers 1 --threads 8 --timeout 0 main:app