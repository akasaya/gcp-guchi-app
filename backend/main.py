from flask import Flask, request, jsonify
from dotenv import load_dotenv
import vertexai
from vertexai.generative_models import GenerativeModel
import os
import json
from flask_cors import CORS

# 環境変数ロード
load_dotenv()
os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = os.getenv("GOOGLE_APPLICATION_CREDENTIALS")

PROJECT_ID = os.getenv("PROJECT_ID")
LOCATION= os.getenv("REGION", "us-central1")
RESOURCE_ID = os.getenv("RESOURCE_ID")

vertexai.init(project=PROJECT_ID, location=LOCATION)

app = Flask(__name__)
CORS(app)
# Geminiモデルの設定
model = GenerativeModel(RESOURCE_ID)

@app.route("/analyze",methods=["POST"])
def analyze_text():
    data = request.get_json()
    user_input = data.get("text","")

    response = model.generate_content(user_input)
    return app.response_class(
        response=json.dumps({"results":response.text},ensure_ascii=False),
        mimetype='application/json'
    )

if __name__=="__main__":
    app.run(debug=True)
