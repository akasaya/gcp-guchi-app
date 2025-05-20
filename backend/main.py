from flask import flask, request, jsonify
import vertexai
from vertexai.generative_models import GenerativeModel
import os



PROJECT_ID = os.getenv("PROJECT_ID")
LOCATION= os.getenv("REGION", "us-central1")
RESOURCE_ID = os.getenv("RESOURCE_ID")

vertexai.init(project=PROJECT_ID, location=LOCATION)

app = flask(__name__)
genai.configure(api_key=os.getenv("GEMINI_API_KEY"))

# Geminiモデルの設定
model = GenerativeModel(RESOURCE_ID)

@app.route("/analyze",methods=["POST"])
def analyze_text():
    data = request.get_json()
    user_input = data.get("text","")

    response = model.generate_content(user_input)
    return jsonify({"result":response.text})

