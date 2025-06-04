import json
import os
import requests # requestsライブラリをインポート
from dotenv import load_dotenv
from flask import Flask, jsonify, request
from flask_cors import CORS
# from vertexai.generative_models import GenerativeModel # Vertex AI SDK - コメントアウト
# import vertexai # Vertex AI SDK - コメントアウト

# 環境変数ロード (ローカル開発用)
load_dotenv()

# --- Ollama用環境変数 ---
print(f"DEBUG: Attempting to load environment variables for Ollama...")
OLLAMA_API_URL = os.getenv("OLLAMA_API_URL")
OLLAMA_MODEL_NAME = os.getenv("OLLAMA_MODEL_NAME", "gemma:7b") # デフォルトモデル名を指定

print(f"DEBUG: OLLAMA_API_URL = {OLLAMA_API_URL}")
print(f"DEBUG: OLLAMA_MODEL_NAME = {OLLAMA_MODEL_NAME}")
# --- ここまでOllama用環境変数 ---

# --- Vertex AI用環境変数 (コメントアウト) ---
# print(f\"DEBUG: Attempting to load environment variables for Vertex AI...\")
# PROJECT_ID = os.getenv(\"PROJECT_ID\")
# LOCATION = os.getenv(\"REGION\", \"us-central1\") # REGION環境変数がなければus-central1をデフォルトに
# モデルIDは DEFAULT_RESOURCE_ID から取得
# RESOURCE_ID = os.getenv(\"DEFAULT_RESOURCE_ID\")
#
# print(f\"DEBUG: PROJECT_ID = {PROJECT_ID}\")
# print(f\"DEBUG: LOCATION = {LOCATION}\")
# print(f\"DEBUG: RESOURCE_ID (Gemma Model ID) = {RESOURCE_ID}\")
# --- ここまでVertex AI用環境変数 ---

# --- Vertex AIの初期化 (コメントアウト) ---
# if not PROJECT_ID:
#     print(\"ERROR: PROJECT_ID environment variable is not set.\")
#     # ここでアプリケーションを終了させるか、エラー処理を行う
#     # exit(1) または raise EnvironmentError(\"PROJECT_ID not set\")
# if not LOCATION:
#     print(\"ERROR: REGION environment variable is not set (or using default).\")
#     # LOCATIONが必須なので、設定されていない場合はエラーとするか、安全なデフォルトを設定する
# if not RESOURCE_ID:
#     print(\"ERROR: DEFAULT_RESOURCE_ID environment variable (for Gemma model) is not set.\")
#     # exit(1) または raise EnvironmentError(\"DEFAULT_RESOURCE_ID not set\")
#
# try:
#     print(f\"DEBUG: Initializing Vertex AI for project \'{PROJECT_ID}\' in location \'{LOCATION}\'...\")
#     vertexai.init(project=PROJECT_ID, location=LOCATION)
#     print(\"DEBUG: Vertex AI initialized successfully.\")
# except Exception as e:
#     print(f\"ERROR: Failed to initialize Vertex AI: {e}\")
#     # 初期化失敗時の処理
#     raise  # エラーを再送出してアプリケーションを停止させるか、適切に処理
# --- ここまでVertex AIの初期化 ---

app = Flask(__name__)
CORS(app)

# --- Vertex AI Gemmaモデルの初期化 (コメントアウト) ---
# model = None # 初期値をNoneに設定
# if RESOURCE_ID:
#     try:
#         print(f\"DEBUG: Loading Gemma model \'{RESOURCE_ID}\'...\")
#         model = GenerativeModel(RESOURCE_ID) # Vertex AI SDKを使用する場合
#         print(f\"DEBUG: Gemma model \'{RESOURCE_ID}\' loaded successfully.\")
#     except Exception as e:
#         print(f\"ERROR: Failed to load Gemma model \'{RESOURCE_ID}\': {e}\")
#         # モデル読み込み失敗時の処理
#         # この場合、modelがNoneのままになる
# else:
#     print(\"INFO: RESOURCE_ID (Gemma model ID) is not set, Vertex AI model will not be loaded.\")
# --- ここまでVertex AI Gemmaモデルの初期化 ---


@app.route("/analyze", methods=["POST"])
def analyze_text():
    # Ollama APIを利用するロジック
    if not OLLAMA_API_URL:
        print("ERROR: OLLAMA_API_URL environment variable is not set.")
        return jsonify({"error": "Ollama API URL not configured."}), 500
    if not OLLAMA_MODEL_NAME:
        print("ERROR: OLLAMA_MODEL_NAME environment variable is not set.")
        return jsonify({"error": "Ollama model name not configured."}), 500

    data = request.get_json()
    if not data:
        return jsonify({"error": "Invalid JSON input"}), 400

    user_input = data.get("text", "")
    if not user_input:
        return jsonify({"error": "Input text ('text') is required."}), 400

    try:
        print(f"DEBUG: Sending request to Ollama API: {OLLAMA_API_URL}/api/generate")
        print(f"DEBUG: Model: {OLLAMA_MODEL_NAME}, Input: '{user_input[:50]}...'")

        payload = {
            "model": OLLAMA_MODEL_NAME,
            "prompt": user_input,
            "stream": False
        }
        
        response = requests.post(f"{OLLAMA_API_URL}/api/generate", json=payload)
        response.raise_for_status()

        ollama_response_json = response.json()
        generated_text = ollama_response_json.get("response", "")

        print("DEBUG: Content generated successfully by Ollama.")
        return app.response_class(
            response=json.dumps({"results": generated_text}, ensure_ascii=False),
            mimetype="application/json",
        )
    except requests.exceptions.RequestException as e:
        print(f"ERROR: Exception during Ollama API request: {e}")
        return jsonify({"error": f"Error communicating with Ollama API. Details: {e}"}), 500
    except Exception as e:
        print(f"ERROR: Exception during Ollama content generation: {e}")
        return jsonify({"error": f"Error generating content with Ollama. Details in server logs."}), 500

    # --- Vertex AIを利用する場合のロジック (コメントアウト) ---
    # if model is None: # Vertex AIモデルがロードされていない場合のチェック
    #     print(\"ERROR: Vertex AI Model is not loaded. Cannot process /analyze request.\")
    #     return jsonify({\"error\": \"Vertex AI Model not available. Check server configuration.\"}), 500
    #
    # data = request.get_json()
    # if not data:
    #     return jsonify({\"error\": \"Invalid JSON input\"}), 400
    #
    # user_input = data.get(\"text\", \"\")
    # if not user_input:
    #     return jsonify({\"error\": \"Input text (\'text\') is required.\"}), 400
    #
    # try:
    #     print(f\"DEBUG: Generating content with Vertex AI Gemma model for input: \'{user_input[:50]}...\'\")
    #     response = model.generate_content(user_input) # Vertex AI SDKを使用する場合
    #     print(\"DEBUG: Content generated successfully by Vertex AI Gemma model.\")
    #     return app.response_class(
    #         response=json.dumps({\"results\": response.text}, ensure_ascii=False),
    #         mimetype=\"application/json\",
    #     )
    # except Exception as e:
    #     print(f\"ERROR: Exception during Vertex AI Gemma model content generation: {e}\")
    #     return jsonify({\"error\": f\"Error generating content with Vertex AI Gemma model. Details in server logs.\"}), 500
    # --- ここまでVertex AIを利用する場合のロジック ---

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 11434))
    app.run(debug=True, host="0.0.0.0", port=port)