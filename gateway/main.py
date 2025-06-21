import firebase_admin
from firebase_admin import credentials, firestore, auth
from flask import Flask, request, jsonify
from flask_cors import CORS

import os
import json
import re
import traceback
import threading
import requests
from bs4 import BeautifulSoup
import numpy as np
import hashlib
from datetime import datetime, timedelta, timezone

from google.cloud import aiplatform
from tenacity import retry, stop_after_attempt, wait_exponential
import vertexai
from vertexai.generative_models import GenerativeModel, GenerationConfig
from vertexai.language_models import TextEmbeddingModel
from google.cloud import discoveryengine_v1 as discoveryengine
from langchain.text_splitter import RecursiveCharacterTextSplitter


# --- GCP & Firebase 初期化 ---
try:
    print("Initializing GCP services using Application Default Credentials...")
    firebase_admin.initialize_app()
    db_firestore = firestore.client()
    
    app_instance = firebase_admin.get_app()
    project_id = app_instance.project_id
    print(f"✅ Firebase Admin SDK initialized for project: {project_id}")

    # (★修正) Vector SearchとGeminiでリージョンを分ける
    # Vector Searchは東京リージョン (`asia-northeast1`) を使用
    vector_search_region = os.getenv('GCP_VERTEX_AI_REGION', 'asia-northeast1')
    # Geminiモデルは米国中部リージョン (`us-central1`) を使用
    gemini_region = os.getenv('GCP_GEMINI_REGION', 'us-central1')
    
    vertexai.init(project=project_id, location=gemini_region)
    print(f"✅ Vertex AI initialized for project: {project_id}. Gemini region: {gemini_region}, Vector Search region: {vector_search_region}")


    # RAG用設定
    SIMILAR_CASES_ENGINE_ID = os.getenv('SIMILAR_CASES_ENGINE_ID')
    SUGGESTIONS_ENGINE_ID = os.getenv('SUGGESTIONS_ENGINE_ID')

    # Vector Search 用設定
    VECTOR_SEARCH_INDEX_ID = os.getenv('VECTOR_SEARCH_INDEX_ID')
    VECTOR_SEARCH_ENDPOINT_ID = os.getenv('VECTOR_SEARCH_ENDPOINT_ID')
    VECTOR_SEARCH_DEPLOYED_INDEX_ID = os.getenv('VECTOR_SEARCH_DEPLOYED_INDEX_ID')
    if 'K_SERVICE' in os.environ:
        if not all([VECTOR_SEARCH_INDEX_ID, VECTOR_SEARCH_ENDPOINT_ID, VECTOR_SEARCH_DEPLOYED_INDEX_ID]):
             print("⚠️ WARNING: Vector Search environment variables are not fully set.")

except Exception as e:
    db_firestore = None
    print(f"❌ Error during initialization: {e}")
    traceback.print_exc()
    if 'K_SERVICE' in os.environ:
        raise

app = Flask(__name__)
# --- CORS設定 ---
prod_origin = "https://guchi-app-flutter.web.app"
if 'K_SERVICE' in os.environ:
    origins = [prod_origin]
else:
    origins = [
        prod_origin,
        re.compile(r"http://localhost:.*"),
        re.compile(r"http://127.0.0.1:.*"),
    ]
CORS(app, resources={r"/*": {"origins": origins}})

@app.route('/', methods=['GET'])
def index():
    return "GuchiSwipe Gateway is running.", 200

# ===== RAG Cache Settings =====
RAG_CACHE_COLLECTION = 'rag_cache'
RAG_CACHE_TTL_DAYS = 7 # Cache expires after 7 days

# ★★★ 修正: セッションの最大ターン数を定義 ★★★
MAX_TURNS = 3 # セッションの最大ターン数（初期ターンを含む）


# ===== JSONスキーマ定義 =====
QUESTIONS_SCHEMA = {"type": "object","properties": {"questions": {"type": "array","items": {"type": "object","properties": {"question_text": {"type": "string"}},"required": ["question_text"]}}},"required": ["questions"]}
SUMMARY_SCHEMA = {"type": "object","properties": {"title": {"type": "string", "description": "このセッション全体を要約する15文字程度の短いタイトル"},"insights": {"type": "string", "description": "指定されたMarkdown形式でのユーザーの心理分析レポート"}},"required": ["title", "insights"]}
GRAPH_SCHEMA = {"type": "object","properties": {"nodes": {"type": "array","items": {"type": "object","properties": {"id": {"type": "string"},"type": {"type": "string", "enum": ["emotion", "topic", "keyword", "issue"]},"size": {"type": "integer"}},"required": ["id", "type", "size"]}},"edges": {"type": "array","items": {"type": "object","properties": {"source": {"type": "string"},"target": {"type": "string"},"weight": {"type": "integer"}},"required": ["source", "target", "weight"]}}},"required": ["nodes", "edges"]}

# ===== プロンプトテンプレート =====
SUMMARY_ONLY_PROMPT_TEMPLATE = """
あなたは、ユーザーの感情の動きを分析するプロの臨床心理士です。ユーザーは「{topic}」というテーマについて対話しています。
以下のユーザーとの会話履歴を分析し、必ず指示通りのJSON形式で分析レポートとタイトルを出力してください。
# 分析対象の会話履歴
{swipes_text}
# 出力形式 (JSON)
必ず以下のキーを持つJSONオブジェクトを生成してください。
- `title`: 会話全体を象徴する15文字程度の短いタイトル。
- `insights`: 以下のMarkdown形式で **厳密に** 記述された分析レポート。
```markdown
### ✨ 全体的な要約
（ここに、ユーザーの現在の心理状態、主な感情、内面的な葛藤などを2〜3文で簡潔にまとめてください）
### 📝 詳細な分析
（ここに、具体的な分析内容を箇条書きで記述してください）
* **感情の状態**: （ユーザーが感じている主要な感情について、その根拠と共に記述してください）
* **注目すべき点**: （回答内容と、ためらい時間から推測される感情の矛盾、特に印象的な回答など、分析の鍵となったポイントを具体的に挙げてください。会話履歴に「特に迷いが見られました」と記載のある回答は、ユーザーがためらいや葛藤を抱えている可能性があります）
* **根本的な課題**: （分析から推測される、ユーザーが直面している根本的な課題や欲求について記述してください）
### 💡 次のステップへの提案
（今回の分析を踏まえ、ユーザーが次回のセッションで深掘りすると良さそうなテーマや、日常生活で意識してみると良いことなどを、具体的かつポジティブな言葉で提案してください）
```
"""
GRAPH_ANALYSIS_PROMPT_TEMPLATE = """
あなたはデータサイエンティストであり、臨床心理士でもあります。
これから渡すテキストは、あるユーザーの複数回のカウンセリングセッションの記録です。
この記録全体を分析し、ユーザーの心理状態の核となる要素を抽出し、それらの関連性を表現するグラフデータを生成してください。
# グラフ生成のルール
1. ノードの種類: `topic`, `issue`, `emotion`, `keyword`
2. ノードの階層: 中心に`topic`と`issue`を配置し、`emotion`や`keyword`はそれらから枝分かれさせる。
3. ノード数の制限: 総数は最大でも15個程度に厳選する。
4. IDの言語: `id`は必ず日本語の単語または短いフレーズにする。
# 出力JSONの仕様
出力は、以下の仕様に厳密に従ったJSON形式のみとすること。 { "nodes": [ ... ], "edges": [ ... ] }
# セッション記録
"""
CHAT_PROMPT_TEMPLATE = """
あなたは、ユーザーの心理分析の専門家であり、共感力と洞察力に優れたカウンセラー「ココロの分析官」です。
ユーザーは、自身の思考を可視化したグラフを見ながら、あなたと対話しようとしています。
# あなたの役割
- ユーザーとの過去の会話履歴と、ユーザーの思考の要約（セッションサマリー）を常に参照し、文脈を維持してください。
- ユーザーの発言を深く傾聴し、まずは肯定的に受け止めて共感を示してください。
- セッションサマリーの内容に基づき、ユーザーが自分でも気づいていない内面を優しく指摘したり、深い問いを投げかけたりして、自己理解を促してください。
- 毎回の返信を自己紹介から始めるのではなく、会話の流れを自然に引き継いでください。
- **ユーザーの名前（「〇〇さん」など）は絶対に使用せず、常に対話相手に直接語りかけるようにしてください。**
# ユーザーのセッションサマリー
{session_summary}
# これまでの会話履歴
{chat_history}
# ユーザーの今回の発言
{user_message}
あなたの応答:
"""
INTERNAL_CONTEXT_PROMPT_TEMPLATE = """
あなたは、ユーザーの過去のカウンセリング記録を要約するアシスタントです。
以下のセッション記録全体から、特定のキーワード「{keyword}」に関連する記述や、そこから推測されるユーザーの感情や葛藤を抜き出し、1〜2文の非常に簡潔な要約を作成してください。
要約は、ユーザーに「以前、この件についてこのようにお話しされていましたね」と自然に語りかける形式で記述してください。
キーワードに直接関連する記述が見つからない場合は、「このテーマについて、これまで具体的なお話はなかったようです。」と出力してください。

# セッション記録
{context}

# 要約:
"""

PROACTIVE_KEYWORDS = [
    "燃え尽き", "バーンアウト", "無気力", "疲弊",
    "キャリア", "転職", "仕事の悩み", "将来設計",
    "対人関係", "孤独", "人間関係", "コミュニケーション",
    "自己肯定感", "自信がない", "自分を責める",
    "ストレス", "プレッシャー", "不安"
]


# ===== Gemini ヘルパー関数群 =====
@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(3))
def _call_gemini_with_schema(prompt: str, schema: dict, model_name: str) -> dict:
    model = GenerativeModel(model_name)
    attempt_num = _call_gemini_with_schema.retry.statistics.get('attempt_number', 1)
    print(f"--- Calling Gemini ({model_name}) with schema (Attempt: {attempt_num}) ---")
    try:
        response = model.generate_content(prompt, generation_config=GenerationConfig(response_mime_type="application/json", response_schema=schema))
        response_text = response.text.strip()
        if response_text.startswith("```json"):
            response_text = response_text[7:-3].strip()
        elif response_text.startswith("```"):
            response_text = response_text[3:-3].strip()
        return json.loads(response_text)
    except Exception as e:
        print(f"Error on attempt {attempt_num} with model {model_name}: {e}\n--- Gemini Response ---\n{getattr(response, 'text', 'Empty')}\n---")
        traceback.print_exc()
        raise

def generate_initial_questions(topic):
    prompt = f"あなたはカウンセラーです。トピック「{topic}」について、「はい」か「いいえ」で答えられる質問を5つ生成してください。"
    flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
    return _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA, model_name=flash_model).get("questions", [])

def generate_follow_up_questions(insights):
    prompt = f"あなたはカウンセラーです。以下の分析結果をさらに深める、「はい」か「いいえ」で答えられる質問を5つ生成してください。\n# 分析結果\n{insights}"
    flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
    return _call_gemini_with_schema(prompt, QUESTIONS_SCHEMA, model_name=flash_model).get("questions", [])

def generate_summary_only(topic, swipes_text):
    prompt = SUMMARY_ONLY_PROMPT_TEMPLATE.format(topic=topic, swipes_text=swipes_text)
    flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
    return _call_gemini_with_schema(prompt, SUMMARY_SCHEMA, model_name=flash_model)

def generate_graph_data(all_insights_text):
    prompt = GRAPH_ANALYSIS_PROMPT_TEMPLATE + all_insights_text
    pro_model = os.getenv('GEMINI_PRO_NAME', 'gemini-1.5-pro-preview-05-20')
    return _call_gemini_with_schema(prompt, GRAPH_SCHEMA, model_name=pro_model)

def generate_chat_response(session_summary, chat_history, user_message, rag_context=""):
    history_str = "\n".join([f"{msg['author']}: {msg['text']}" for msg in chat_history])
    
    if rag_context:
        # RAGコンテキストがある場合、プロンプトに追加
        prompt = f"""
あなたは、ユーザーの心理分析の専門家であり、共感力と洞察力に優れたカウンセラー「ココロの分析官」です。
ユーザーは、自身の思考を可視化したグラフを見ながら、あなたと対話しようとしています。
# あなたの役割
- ユーザーとの過去の会話履歴と、ユーザーの思考の要約（セッションサマリー）を常に参照し、文脈を維持してください。
- ユーザーの発言を深く傾聴し、まずは肯定的に受け止めて共感を示してください。
- **以下の参考情報を元に**、ユーザーが自分でも気づいていない内面を優しく指摘したり、深い問いを投げかけたりして、自己理解を促してください。
- 毎回の返信を自己紹介から始めるのではなく、会話の流れを自然に引き継いでください。
- **ユーザーの名前（「〇〇さん」など）は絶対に使用せず、常に対話相手に直接語りかけるようにしてください。**
# ユーザーのセッションサマリー
{session_summary}
# 参考情報
{rag_context}
# これまでの会話履歴
{history_str}
# ユーザーの今回の発言
{user_message}
あなたの応答:
"""
    else:
        # RAGコンテキストがない場合は、元のプロンプトを使用
        prompt = CHAT_PROMPT_TEMPLATE.format(session_summary=session_summary, chat_history=history_str, user_message=user_message)

    pro_model = os.getenv('GEMINI_PRO_NAME', 'gemini-1.5-pro-preview-05-20')
    model = GenerativeModel(pro_model)
    return model.generate_content(prompt).text.strip()


@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(3))
def _extract_keywords_for_search(analysis_text: str) -> str:
    prompt = f"""
以下のユーザー心理分析レポート全体から、最も重要と思われる概念や課題を示すキーワードを5つ以内で抽出してください。
キーワードはVertex AI Searchの検索クエリとして使用します。他の文は含めず、キーワードをカンマ区切りの文字列のみで出力してください。

# 分析レポート
{analysis_text}

# 出力例
仕事のプレッシャー, 人間関係の悩み, 自己肯定感の低下, 将来への不安

# キーワード:
"""
    try:
        flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
        model = GenerativeModel(flash_model)
        print("--- Calling Gemini to extract search keywords ---")
        response = model.generate_content(prompt)
        keywords = response.text.strip()
        print(f"✅ Extracted Keywords: {keywords}")
        return keywords
    except Exception as e:
        print(f"❌ Failed to extract keywords: {e}")
        return ""

def _summarize_internal_context(context: str, keyword: str) -> str:
    """Summarizes past session records related to a specific keyword."""
    if not context or not keyword:
        return "このテーマについて、これまで具体的なお話はなかったようです。"
    try:
        prompt = INTERNAL_CONTEXT_PROMPT_TEMPLATE.format(context=context, keyword=keyword)
        flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
        model = GenerativeModel(flash_model)
        print(f"--- Calling Gemini to summarize internal context for '{keyword}' ---")
        response = model.generate_content(prompt)
        summary = response.text.strip()
        print(f"✅ Internal context summary: {summary}")
        return summary
    except Exception as e:
        print(f"❌ Failed to summarize internal context: {e}")
        return "過去の記録を要約中にエラーが発生しました。"

# ===== RAG (Retrieval-Augmented Generation) Helper Functions =====

@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(3))
def _get_embeddings(texts: list[str]) -> list[list[float]]:
    if not texts: return []
    model = TextEmbeddingModel.from_pretrained("text-multilingual-embedding-002")
    BATCH_SIZE = 15 
    all_embeddings = []
    print(f"--- RAG: Generating embeddings for {len(texts)} texts in batches of {BATCH_SIZE} ---")
    try:
        for i in range(0, len(texts), BATCH_SIZE):
            batch = texts[i:i + BATCH_SIZE]
            responses = model.get_embeddings(batch)
            for response in responses:
                all_embeddings.append(response.values)
            print(f"--- RAG: Processed embedding batch {i//BATCH_SIZE + 1}/{-(-len(texts) // BATCH_SIZE)} ---")
        return all_embeddings
    except Exception as e:
        print(f"❌ RAG: An error occurred during embedding generation: {e}")
        traceback.print_exc()
        return []

def _get_url_cache_doc_ref(url: str):
    url_hash = hashlib.sha256(url.encode('utf-8')).hexdigest()
    return db_firestore.collection(RAG_CACHE_COLLECTION).document(url_hash)

def _get_cached_chunks_and_embeddings(url: str):
    try:
        doc_ref = _get_url_cache_doc_ref(url)
        doc = doc_ref.get()
        if not doc.exists:
            print(f"CACHE MISS: No cache found for URL: {url}")
            return None, None
        cache_data = doc.to_dict()
        cached_at = cache_data.get('cached_at')
        if isinstance(cached_at, datetime):
            if datetime.now(timezone.utc) - cached_at > timedelta(days=RAG_CACHE_TTL_DAYS):
                print(f"CACHE STALE: Cache for {url} is older than {RAG_CACHE_TTL_DAYS} days.")
                return None, None
        else:
             print(f"CACHE INVALID: Invalid 'cached_at' field for {url}.")
             return None, None
        
        chunks = cache_data.get('chunks')
        embeddings_from_db = cache_data.get('embeddings')
        
        if chunks and embeddings_from_db:
            embeddings = [item['vector'] for item in embeddings_from_db if 'vector' in item]
            if len(chunks) == len(embeddings):
                print(f"✅ CACHE HIT: Found {len(chunks)} chunks for URL: {url}")
                return chunks, embeddings

        print(f"CACHE INVALID: Data mismatch for {url}. Re-fetching.")
        return None, None
    except Exception as e:
        print(f"❌ Error getting cache for {url}: {e}")
        return None, None

def _set_cached_chunks_and_embeddings(url: str, chunks: list, embeddings: list):
    if not chunks or not embeddings: return
    try:
        doc_ref = _get_url_cache_doc_ref(url)
        transformed_embeddings = [{'vector': emb} for emb in embeddings]
        cache_data = {
            'url': url,
            'chunks': chunks,
            'embeddings': transformed_embeddings,
            'cached_at': firestore.SERVER_TIMESTAMP
        }
        doc_ref.set(cache_data)
        print(f"✅ CACHE SET: Saved {len(chunks)} chunks for URL: {url}")
    except Exception as e:
        print(f"❌ Error setting cache for {url}: {e}")
        traceback.print_exc()

def _generate_rag_based_advice(query: str, project_id: str, similar_cases_engine_id: str, suggestions_engine_id: str, rag_type: str = None):
    """
    RAG based on user analysis to generate advice, using a Firestore cache for embeddings.
    Returns a tuple of (advice_text, list_of_source_urls).
    """
    search_query = _extract_keywords_for_search(query)
    if not search_query:
        print("⚠️ RAG: Could not extract keywords. Using original query for search.")
        search_query = query[:512]
    
    all_found_urls = set()
    if rag_type == 'similar_cases':
        print("--- RAG: Searching for SIMILAR CASES ONLY ---")
        if similar_cases_engine_id:
            all_found_urls.update(_search_with_vertex_ai_search(project_id, "global", similar_cases_engine_id, search_query))
    elif rag_type == 'suggestions':
        print("--- RAG: Searching for SUGGESTIONS ONLY ---")
        if suggestions_engine_id:
            all_found_urls.update(_search_with_vertex_ai_search(project_id, "global", suggestions_engine_id, search_query))
    else: # Default behavior: search both
        print("--- RAG: Searching both similar cases and suggestions ---")
        if similar_cases_engine_id:
            all_found_urls.update(_search_with_vertex_ai_search(project_id, "global", similar_cases_engine_id, search_query))
        if suggestions_engine_id:
            all_found_urls.update(_search_with_vertex_ai_search(project_id, "global", suggestions_engine_id, search_query))

    if not all_found_urls:
        return "関連する外部情報を見つけることができませんでした。", []

    all_chunks, all_embeddings, urls_with_content = [], [], []
    urls_to_process = list(all_found_urls)[:5]

    for url in urls_to_process:
        cached_chunks, cached_embeddings = _get_cached_chunks_and_embeddings(url)
        if cached_chunks and cached_embeddings:
            all_chunks.extend(cached_chunks)
            all_embeddings.extend(cached_embeddings)
            urls_with_content.append(url)
        else:
            print(f"SCRAPING: No valid cache for {url}. Fetching content.")
            page_content = _scrape_text_from_url(url)
            if page_content:
                text_splitter = RecursiveCharacterTextSplitter(chunk_size=1500, chunk_overlap=150)
                new_chunks_full = text_splitter.split_text(page_content)
                
                MAX_CHUNKS_PER_URL = 50  # 1つのURLから取得するチャンクの上限
                new_chunks = new_chunks_full[:MAX_CHUNKS_PER_URL]

                if len(new_chunks_full) > MAX_CHUNKS_PER_URL:
                    print(f"⚠️ RAG: Content too long. Truncated chunks for {url} from {len(new_chunks_full)} to {len(new_chunks)}.")
                if new_chunks:
                    new_embeddings = _get_embeddings(new_chunks)
                    if new_embeddings and len(new_chunks) == len(new_embeddings):
                        all_chunks.extend(new_chunks)
                        all_embeddings.extend(new_embeddings)
                        urls_with_content.append(url)
                        threading.Thread(target=_set_cached_chunks_and_embeddings, args=(url, new_chunks, new_embeddings)).start()
                    else:
                        print(f"⚠️ RAG: Failed to generate embeddings for {url}. Skipping.")
    
    if not all_chunks:
        return "関連する外部情報を見つけましたが、内容を読み取ることができませんでした。", urls_to_process

    print(f"--- RAG: Finding relevant chunks from {len(all_chunks)} total chunks... ---")
    query_embedding_list = _get_embeddings([query])
    if not query_embedding_list:
        return "あなたの状況を分析できませんでした。もう一度お試しください。", urls_with_content
    
    query_embedding = np.array(query_embedding_list[0])
    
    similarities = []
    for i, emb in enumerate(all_embeddings):
        chunk_embedding = np.array(emb)
        dot_product = np.dot(chunk_embedding, query_embedding)
        norm_product = np.linalg.norm(chunk_embedding) * np.linalg.norm(query_embedding)
        similarity = dot_product / norm_product if norm_product != 0 else 0.0
        similarities.append((similarity, all_chunks[i]))
    
    similarities.sort(key=lambda x: x[0], reverse=True)
    relevant_chunks = [chunk for sim, chunk in similarities[:3]]

    if not relevant_chunks:
        return "関連情報の中から、あなたの状況に特に合致する部分を見つけ出すことができませんでした。", urls_with_content

    print("--- RAG: Generating final advice with Gemini... ---")
    context_text = "\n---\n".join(relevant_chunks)

    if rag_type == 'similar_cases':
        prompt = f"""
あなたは、ユーザーの悩みに共感し、他の人のケースを紹介する聞き上手な友人です。
以下の「ユーザー分析結果」と「参考情報（他の人の悩みや体験談）」を元に、ユーザーを励ますような形で、参考情報を要約してください。

# 指示
- 全体で200文字程度の、非常にコンパクトな文章で要約してください。
- ユーザーを安心させ、一人ではないと感じさせるような、温かく共感的なトーンで記述してください。
- 「似たようなことで悩んでいる方もいるようです。」といった前置きから始めてください。
- 最後に、参考にした情報源のURLを `[参考情報]` として箇条書きで必ず含めてください。

# ユーザー分析結果
{query}

# 参考情報 (他の人の悩みや体験談)
---
{context_text}
---

# あなたの応答:
"""
    else: # 'suggestions' or default
        prompt = f"""
あなたは、客観的で信頼できるアドバイスを提供するプロのカウンセラーです。
以下の「ユーザー分析結果」と「参考情報（専門機関による具体的な対策）」を元に、ユーザーが次の一歩を踏み出すための、具体的で実践的なアドバイスを生成してください。

# 指示
- 全体で300文字程度の、簡潔かつ分かりやすい文章で記述してください。
- ユーザーの状況を整理し、具体的なアクションを箇条書きで2〜3点提案する構成にしてください。
- 「あなたの状況を客観的に見ると、次のステップとして、このようなことが考えられます。」といった、専門家としての冷静なトーンで始めてください。
- 最後に、参考にした情報源のURLを `[参考情報]` として箇条書きで必ず含めてください。

# ユーザー分析結果
{query}

# 参考情報 (専門機関による具体的な対策)
---
{context_text}
---

# あなたの応答:
"""

    pro_model_name = os.getenv('GEMINI_PRO_NAME', 'gemini-1.5-pro-preview-05-20')
    model = GenerativeModel(pro_model_name)
    advice = model.generate_content(prompt, generation_config=GenerationConfig(temperature=0.7)).text
    
    return advice, list(dict.fromkeys(urls_with_content))

def _search_with_vertex_ai_search(project_id: str, location: str, engine_id: str, query: str) -> list[str]:
    if not engine_id:
        print(f"❌ RAG: Engine ID '{engine_id}' is not configured.")
        return []
    client = discoveryengine.SearchServiceClient()
    serving_config = (
        f"projects/{project_id}/locations/{location}/collections/default_collection/"
        f"engines/{engine_id}/servingConfigs/default_config"
    )
    request = discoveryengine.SearchRequest(serving_config=serving_config, query=query, page_size=5)
    try:
        response = client.search(request)
        urls = [r.document.derived_struct_data.get('link') for r in response.results if r.document.derived_struct_data.get('link')]
        print(f"✅ RAG: Found URLs from Vertex AI Search: {urls}")
        return urls
    except Exception as e:
        print(f"❌ RAG: Vertex AI Search failed for engine '{engine_id}': {e}")
        traceback.print_exc()
        return []

def _scrape_text_from_url(url: str) -> str:
    try:
        headers = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3'}
        response = requests.get(url, timeout=10, headers=headers)
        response.raise_for_status()
        response.encoding = response.apparent_encoding
        soup = BeautifulSoup(response.text, 'html.parser')
        for element in soup(["script", "style", "header", "footer", "nav", "aside"]):
            element.decompose()
        return soup.get_text(separator=' ', strip=True)
    except requests.exceptions.RequestException as e:
        print(f"❌ RAG: Error fetching URL {url}: {e}")
        return ""

# --- バックグラウンド処理 ---
def _prefetch_questions_and_save(session_id: str, user_id: str, insights_md: str, current_turn: int, max_turns: int):
    print(f"--- Triggered question prefetch for user: {user_id}, session: {session_id}, next_turn: {current_turn + 1} ---")
    if current_turn >= max_turns:
        print("Max turns reached. Skipping question prefetch.")
        return
    try:
        questions = generate_follow_up_questions(insights=insights_md)
        if questions:
            prefetched_ref = db_firestore.collection('sessions').document(session_id).collection('prefetched_questions').document(str(current_turn + 1))
            prefetched_ref.set({'questions': questions})
            print(f"✅ Prefetched and saved questions for turn {current_turn + 1}")
    except Exception as e:
        print(f"❌ Error during question prefetch for session {session_id}: {e}")

def _update_graph_cache(user_id: str):
    print(f"--- Triggered background graph update for user: {user_id} ---")
    try:
        _get_graph_from_cache_or_generate(user_id, force_regenerate=True)
        print(f"✅ Background graph update for user {user_id} completed.")
    except Exception as e:
        print(f"❌ Error during background graph update for user {user_id}: {e}")


# ===== 認証・認可 =====
def _verify_token(request):
    auth_header = request.headers.get('Authorization')
    if not auth_header:
        # 失敗時はResponseオブジェクトが返る
        return jsonify({"error": "Authorization header is missing"}), 401

    try:
        id_token = auth_header.split('Bearer ')[1]
        # 成功時はdictが返る
        decoded_token = auth.verify_id_token(id_token)
        return decoded_token
    except (IndexError, auth.InvalidIdTokenError) as e:
        print(f"Token validation failed: {e}")
        # 失敗時はResponseオブジェクトが返る
        return jsonify({"error": "Invalid or expired token"}), 401
    except Exception as e:
        print(f"An unexpected error occurred during token verification: {e}")
        return jsonify({"error": "Could not verify token"}), 500



# ===== APIエンドポイント =====
@app.route('/session/start', methods=['POST'])
def start_session():
    user_record = _verify_token(request)
    if not isinstance(user_record, dict):
        return user_record

    data = request.get_json()
    if not data or 'topic' not in data:
        return jsonify({"error": "Topic is required"}), 400
    
    topic = data['topic']
    user_id = user_record['uid']
    
    try:
        # (★修正) セッションの保存先をユーザーのサブコレクションに変更
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document()
        
        # (★修正) status と created_at を追加
        session_doc_ref.set({
            'user_id': user_id,
            'topic': topic,
            'created_at': firestore.SERVER_TIMESTAMP, # 日付順で並び替えるために必要
            'status': 'processing', # statusを 'processing' で初期化
            'turn': 1,
        })

        # Geminiで最初の質問を生成
        questions = generate_initial_questions(topic)

        # バッチ書き込みを使って質問を保存し、同時にフロントエンド用のレスポンスを作成
        batch = db_firestore.batch()
        
        questions_for_response = []
        for question in questions:
            # 質問用のドキュメント参照を先に作成してIDを取得
            question_doc_ref = session_doc_ref.collection('questions').document()
            
            # フロントに返すリストには、生成したIDを `question_id` として追加
            questions_for_response.append({
                "question_text": question['question_text'],
                "question_id": question_doc_ref.id
            })
            
            # Firestoreには、質問テキストのみをバッチに追加
            batch.set(question_doc_ref, { "question_text": question['question_text'] })

        batch.commit()

        return jsonify({
            'session_id': session_doc_ref.id,
            'questions': questions_for_response
        }), 200

    except Exception as e:
        print(f"Error starting session: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to start session"}), 500

@app.route('/session/<string:session_id>/swipe', methods=['POST'])
def record_swipe(session_id):
    user_record = _verify_token(request)
    if not isinstance(user_record, dict):
        return user_record
    user_id = user_record['uid']

    data = request.get_json()
    required_fields = ['question_id', 'answer', 'hesitation_time', 'speed', 'turn']
    if not data or not all(field in data for field in required_fields):
        return jsonify({"error": "Missing required fields in request"}), 400
    
    try:
        # (★修正) セッションの参照パスをユーザーのサブコレクションに変更
        session_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        swipe_ref = session_ref.collection('swipes').document()
        
        swipe_ref.set({
            'user_id': user_record['uid'],
            'question_id': data['question_id'],
            'answer': data['answer'],
            'hesitation_time': data['hesitation_time'],
            'swipe_speed': data['speed'],
            'turn': data['turn'],
            'timestamp': firestore.SERVER_TIMESTAMP
        })

        return jsonify({"status": "success"}), 200

    except Exception as e:
        print(f"Error recording swipe: {e}")
        return jsonify({"error": "Failed to record swipe"}), 500


@app.route('/session/<string:session_id>/summary', methods=['POST'])
def post_summary(session_id):
    """セッションの要約を生成・保存し、結果を返す"""
    user_record = _verify_token(request)
    # ★★★ 修正: 認証成功時はdict型、失敗時はResponseオブジェクトが返るため、dict型かどうかで判定する ★★★
    if not isinstance(user_record, dict):
        return user_record
    user_id = user_record['uid']


    # (★修正) セッションの参照パスをユーザーのサブコレクションに変更
    session_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
    session_snapshot = session_ref.get()

    if not session_snapshot.exists:
        return jsonify({"error": "Session not found"}), 404

    try:
        session_data = session_snapshot.to_dict()
        topic = session_data.get('topic', '指定なし')
        current_turn = session_data.get('turn', 1) 
        swipes_ref = session_ref.collection('swipes').order_by('timestamp')
        swipes_docs = list(swipes_ref.stream())

        if not swipes_docs:
            print(f"No swipes found for session {session_id}, returning empty summary.")
            # (★修正) statusをcompletedにしておく
            session_ref.update({'status': 'completed', 'title': '対話の記録がありません'})
            return jsonify({
                "title": "対話の記録がありません",
                "insights": "今回は対話の記録がなかったため、要約の作成をスキップしました。",
                "turn": session_data.get('turn', 1),
                "max_turns": MAX_TURNS
            }), 200

        # (★修正) 質問テキストを取得するためにquestionsコレクションを引く
        questions_ref = session_ref.collection('questions')
        questions_docs = {q.id: q.to_dict() for q in questions_ref.stream()}
        
        swipes_text_parts = []
        for s_doc in swipes_docs:
            s = s_doc.to_dict()
            q_id = s.get('question_id')
            q_text = questions_docs.get(q_id, {}).get('question_text', '不明な質問')
            answer_text = 'はい' if s.get('answer') else 'いいえ'
            hesitation_time = s.get('hesitation_time', 0)
            swipes_text_parts.append(f"- {q_text}: {answer_text} ({hesitation_time:.2f}秒)")
            
        swipes_text = "\n".join(swipes_text_parts)
        
        summary_data = generate_summary_only(topic, swipes_text)

        # (★修正) アプリの仕様に合わせてトップレベルにフィールドを更新
        update_data = {
            'status': 'completed',
            'title': summary_data.get('title'),
            'latest_insights': summary_data.get('insights'),
            'updated_at': firestore.SERVER_TIMESTAMP
        }
        session_ref.update(update_data)

       # ★★★ 修正: summariesサブコレクションに「ターンごと」の分析結果を保存 ★★★
        summary_with_turn = summary_data.copy()
        summary_with_turn['turn'] = current_turn # ドキュメント内にターン番号を保存
        summary_ref = session_ref.collection('summaries').document(f'turn_{current_turn}')
        summary_ref.set(summary_with_turn)

        response_data = summary_data.copy()
        response_data['turn'] = session_data.get('turn', 1)
        response_data['max_turns'] = MAX_TURNS

        # バックグラウンド処理の呼び出し
        insights_text = summary_data.get('insights', '')
        current_turn = response_data['turn']
        threading.Thread(target=_prefetch_questions_and_save, args=(session_id, user_id, insights_text, current_turn, MAX_TURNS)).start()
        threading.Thread(target=_update_graph_cache, args=(user_id,)).start()
        
        return jsonify(response_data), 200
    except Exception as e:
        print(f"❌ Error in post_summary for session {session_id}: {e}")
        traceback.print_exc()
        # (★修正) エラー時にもstatusを更新
        session_ref.update({'status': 'error', 'error_message': str(e)})
        return jsonify({"error": "Failed to generate summary"}), 500


@app.route('/session/<string:session_id>/continue', methods=['POST'])
def continue_session(session_id):
    user_record = _verify_token(request)
    if not isinstance(user_record, dict):
        return user_record

    user_id = user_record['uid']

    try:
        session_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)

        @firestore.transactional
        def update_turn(transaction, ref):
            snapshot = ref.get(transaction=transaction)
            if not snapshot.exists:
                raise Exception("Session not found")
            
            current_turn = snapshot.to_dict().get('turn', 1)
            new_turn = current_turn + 1
            
            if new_turn > MAX_TURNS:
                 return None, None

            transaction.update(ref, {
                'turn': new_turn,
                'status': 'processing', # ★ 状態を「進行中」に戻す
                'last_updated': firestore.SERVER_TIMESTAMP
            })
            return new_turn

        transaction = db_firestore.transaction()
        new_turn = update_turn(transaction, session_ref)

        if new_turn is None:
            return jsonify({"error": "Maximum turns reached for this session."}), 400
        
        prefetched_ref = session_ref.collection('prefetched_questions').document(str(new_turn))
        prefetched_doc = prefetched_ref.get()

        generated_questions = []
        if prefetched_doc.exists:
            print(f"✅ Using prefetched questions for turn {new_turn}")
            generated_questions = prefetched_doc.to_dict().get('questions', [])
            prefetched_ref.delete()
        else:
            print(f"⚠️ No prefetched questions found for turn {new_turn}. Generating now...")
            latest_summary_query = session_ref.collection('summaries').order_by('turn', direction=firestore.Query.DESCENDING).limit(1)
            latest_summary_docs = list(latest_summary_query.stream())
            if not latest_summary_docs:
                 return jsonify({"error": "Summary not found to generate follow-up questions"}), 404
            
            insights = latest_summary_docs[0].to_dict().get('insights', '')
            generated_questions = generate_follow_up_questions(insights)

        # ★★★ ここからが今回の修正の核心部分です ★★★
        # 1. バッチ処理を開始
        batch = db_firestore.batch()
        # 2. フロントエンドに返すための、ID付き質問リストを初期化
        questions_with_ids = []

        # 3. 生成された質問をループ処理
        for q in generated_questions:
            # a. 新しい質問のためのドキュメント参照を作成（ここでIDが自動生成される）
            q_ref = session_ref.collection('questions').document()
            # b. バッチに「質問テキストをDBに保存する」処理を追加
            batch.set(q_ref, {"question_text": q['question_text']})
            # c. フロントに返すリストに、「ID」と「質問テキスト」を追加
            questions_with_ids.append({
                "question_id": q_ref.id,
                "question_text": q['question_text']
            })
        
        # 4. バッチ処理を実行し、すべての質問をDBに一括保存
        batch.commit()
        # ★★★ ここまでが修正の核心部分です ★★★

        # 5. DB保存後のID付き質問リストをフロントエンドに返す
        return jsonify({'questions': questions_with_ids, 'turn': new_turn}), 200

    except Exception as e:
        print(f"Error continuing session: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to continue session"}), 500


def _get_all_insights_as_text(user_id: str) -> str:
    """指定されたユーザーの全てのセッションサマリーをテキストとして結合する"""
    print(f"--- Fetching all session insights for user: {user_id} ---")
    all_insights_text = ""
    try:
        # (★修正) セッションの参照パスをユーザーのサブコレクションに変更
        sessions_ref = db_firestore.collection('users').document(user_id).collection('sessions').where('status', '==', 'completed').order_by('created_at', direction=firestore.Query.DESCENDING).limit(10)
        sessions_docs = sessions_ref.stream()

        for session in sessions_docs:
            session_dict = session.to_dict()
            # (★修正) created_at, topic, title, latest_insights を直接取得
            session_date = session_dict.get("created_at").strftime('%Y-%m-%d') if session_dict.get("created_at") else "不明な日付"
            session_topic = session_dict.get("topic", "不明なトピック")
            title = session_dict.get('title', '無題')
            insights = session_dict.get('latest_insights', '分析結果がありません。')
            
            summary_text_parts = [
                f"## セッション記録 ({session_date} - {session_topic})",
                f"### {title}\n{insights}"
            ]
            all_insights_text += "\n\n" + "\n".join(summary_text_parts)

        print(f"✅ Found and compiled insights from past sessions.")
        return all_insights_text.strip()
    except Exception as e:
        print(f"❌ Error fetching insights for user {user_id}: {e}")
        return ""



@app.route('/analysis/graph', methods=['GET'])
def get_analysis_graph():
    """ユーザーの全セッション履歴から統合分析グラフを生成またはキャッシュから取得"""
    user_record = _verify_token(request)
    # ★★★ 修正: 認証成功時はdict型、失敗時はResponseオブジェクトが返るため、dict型かどうかで判定する ★★★
    if not isinstance(user_record, dict):
        return user_record
    
    user_id = user_record['uid']
    try:
        graph_data = _get_graph_from_cache_or_generate(user_id)
        if graph_data:
            return jsonify(graph_data), 200
        else:
            return jsonify({"error": "No data available to generate graph"}), 404
    except Exception as e:
        print(f"❌ Error in get_analysis_graph: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to get analysis graph"}), 500


def _get_graph_from_cache_or_generate(user_id: str, force_regenerate: bool = False):
    """
    Firestoreのキャッシュからグラフデータを取得する。
    キャッシュがない場合やforce_regenerate=Trueの場合は、新たに生成してキャッシュに保存する。
    """
    cache_ref = db_firestore.collection('analysis_cache').document(user_id)
    
    if not force_regenerate:
        cache_doc = cache_ref.get()
        if cache_doc.exists:
            cached_data = cache_doc.to_dict()
            # 24時間以内であればキャッシュを返す
            if datetime.now(timezone.utc) - cached_data['timestamp'] < timedelta(hours=24):
                print(f"✅ Returning cached graph data for user: {user_id}")
                return cached_data['graph_data']

    print(f"--- Generating new graph data for user: {user_id} (force_regenerate={force_regenerate}) ---")
    all_insights_text = _get_all_insights_as_text(user_id)
    if not all_insights_text:
        return None

    graph_data = generate_graph_data(all_insights_text)
    
    # 新しいグラフデータをキャッシュに保存
    cache_ref.set({
        'graph_data': graph_data,
        'timestamp': firestore.SERVER_TIMESTAMP,
        'user_id': user_id
    })
    print(f"✅ Generated and cached new graph data for user: {user_id}")
    
    return graph_data


@app.route('/home/suggestion', methods=['GET'])
def get_home_suggestion():
    """ホーム画面に表示する、過去の対話に基づく提案を返す"""
    user_record = _verify_token(request)
    # ★★★ 修正: 認証成功時はdict型、失敗時はResponseオブジェクトが返るため、dict型かどうかで判定する ★★★
    if not isinstance(user_record, dict):
        return user_record

    user_id = user_record['uid'] 
    print(f"--- Received home suggestion request for user: {user_id} ---")

    try:
        graph_data = _get_graph_from_cache_or_generate(user_id)
        if not graph_data or 'nodes' not in graph_data or not graph_data['nodes']:
            print("No graph data available for suggestion.")
            return jsonify({}), 204 # 提案なし

        nodes = graph_data['nodes']
        
        # タイプが 'issue' または 'topic' のノードを優先的に抽出
        priority_nodes = [n for n in nodes if n.get('type') in ['issue', 'topic']]
        
        # 優先ノードがない場合は、全ノードから選ぶ
        target_nodes = priority_nodes if priority_nodes else nodes

        # ノードをサイズ（重要度）で降順にソート
        sorted_nodes = sorted(target_nodes, key=lambda x: x.get('size', 0), reverse=True)
        
        if not sorted_nodes:
            print("No suitable nodes found for suggestion.")
            return jsonify({}), 204

        # 最も重要なノードを提案として選択
        suggestion_node = sorted_nodes[0]
        node_label = suggestion_node.get('id', '不明なトピック')
        
        response_data = {
            "title": "過去の対話を振り返ってみませんか？",
            "subtitle": f"「{node_label}」について、新たな発見があるかもしれません。",
            "nodeId": node_label, 
            "nodeLabel": node_label
        }
        print(f"✅ Sending suggestion: {response_data}")
        return jsonify(response_data), 200

    except Exception as e:
        print(f"❌ Error in get_home_suggestion: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to get home suggestion"}), 500


@app.route('/analysis/proactive_suggestion', methods=['GET'])
def get_proactive_suggestion():
    """
    ユーザーの分析グラフ全体から、能動的な気付きを促すための質問やコンテキストを生成する。
    1. グラフデータからキーワードを抽出
    2. 抽出したキーワードで内部（過去の対話）と外部（Web検索）を検索
    3. 結果をGeminiで要約し、ユーザーへの提案を生成
    """
    user_record = _verify_token(request)
    if not isinstance(user_record, dict):
        return user_record

    user_id = user_record['uid']
    print(f"--- Received proactive suggestion request for user: {user_id} ---")

    try:
        # 1. グラフデータ（=ユーザーの思考の全体像）を取得
        graph_data = _get_graph_from_cache_or_generate(user_id)
        if not graph_data or 'nodes' not in graph_data or not graph_data['nodes']:
            print("No graph data available for proactive suggestion.")
            return jsonify({}), 204

        # 2. グラフからキーワードを抽出 (nodeのidを結合)
        graph_keywords = ", ".join([node.get('id', '') for node in graph_data['nodes']])
        if not graph_keywords:
            print("No keywords found in graph.")
            return jsonify({}), 204
        
        print(f"Keywords from graph: {graph_keywords}")

        # 3. 内部コンテキスト（過去の対話）を要約
        all_insights_text = _get_all_insights_as_text(user_id)
        # グラフ全体のキーワードの中から、特に重要なキーワードをランダムに選んで文脈を要約
        chosen_keyword = np.random.choice(PROACTIVE_KEYWORDS)
        internal_summary = _summarize_internal_context(all_insights_text, chosen_keyword)

        # 4. 外部コンテキスト（Web検索）を取得
        # 検索クエリをGeminiで生成
        search_query_prompt = f"""
以下のキーワード群は、あるユーザーの悩みや関心事を表しています。
このユーザーにとって、現状を乗り越えるための具体的なヒントや、客観的な情報を提供するための、効果的なWeb検索クエリを1つ生成してください。
キーワード: {graph_keywords}
検索クエリ:"""
        
        flash_model = os.getenv('GEMINI_FLASH_NAME', 'gemini-1.5-flash-preview-05-20')
        model = GenerativeModel(flash_model)
        search_query = model.generate_content(search_query_prompt).text.strip()
        print(f"Generated search query: {search_query}")

        external_summary, sources = _generate_rag_based_advice(
            query=search_query,
            project_id=project_id,
            similar_cases_engine_id=SIMILAR_CASES_ENGINE_ID,
            suggestions_engine_id=SUGGESTIONS_ENGINE_ID,
            rag_type="suggestions" # 具体的な対策を検索
        )

        # 5. Geminiで最終的な提案を生成
        final_prompt = f"""
あなたはユーザーの良き相談相手であり、新たな視点を提供するコーチです。
以下の情報を元に、ユーザーが「なるほど、そんな考え方もあるのか」とハッとするような、優しくも洞察に満ちた語りかけを生成してください。

# あなたへのインプット
- ユーザーが過去に話した内容の要約: {internal_summary}
- 関連する外部情報の要約: {external_summary}
- 参考情報源URL: {", ".join(sources) if sources else "なし"}

# あなたのタスク
1. 上記のインプットを統合し、ユーザーへの語りかけメッセージを作成してください。
2. メッセージは、ユーザーを励まし、次の一歩を考えるきっかけを与えるような、ポジティブなトーンで記述してください。
3. 必ず、最終的な出力は以下のキーを持つJSON形式にしてください。
   - `initialSummary`: ユーザーへの語りかけメッセージ（200文字程度）
   - `actions`: ユーザーが次に何をすべきかの具体的な選択肢（空の配列でOK）
   - `nodeLabel`: 'AIからの提案' という固定文字列
   - `nodeId`: 'proactive_suggestion' という固定文字列
"""
        
        pro_model = os.getenv('GEMINI_PRO_NAME', 'gemini-1.5-pro-preview-05-20')
        response_json = _call_gemini_with_schema(
            final_prompt,
            schema={
                "type": "object",
                "properties": {
                    "initialSummary": {"type": "string"},
                    "actions": {"type": "array", "items": {"type": "string"}},
                    "nodeLabel": {"type": "string"},
                    "nodeId": {"type": "string"}
                },
                "required": ["initialSummary", "actions", "nodeLabel", "nodeId"]
            },
            model_name=pro_model
        )

        print(f"✅ Sending proactive suggestion: {response_json}")
        return jsonify(response_json), 200

    except Exception as e:
        print(f"❌ Error in get_proactive_suggestion: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to get proactive suggestion"}), 500


@app.route('/chat/node_tap', methods=['POST'])
def handle_node_tap():
    """グラフ上のノードがタップされた時に、関連情報を返す"""
    user_record = _verify_token(request)
    # ★★★ 修正: 認証成功時はdict型、失敗時はResponseオブジェクトが返るため、dict型かどうかで判定する ★★★
    if not isinstance(user_record, dict):
        return user_record

    data = request.get_json()
    if not data or 'node_label' not in data:
        return jsonify({"error": "node_label is required"}), 400

    node_label = data['node_label']
    user_id = user_record['uid']

    try:
        # 1. 内部コンテキスト（過去の対話）を要約
        all_insights_text = _get_all_insights_as_text(user_id)
        internal_summary = _summarize_internal_context(all_insights_text, node_label)
        
        # 2. 外部コンテキスト（Web検索）を取得
        external_summary_cases, sources_cases = _generate_rag_based_advice(
            query=f"{node_label}に関する悩み",
            project_id=project_id,
            similar_cases_engine_id=SIMILAR_CASES_ENGINE_ID,
            suggestions_engine_id=SUGGESTIONS_ENGINE_ID,
            rag_type="similar_cases"
        )
        external_summary_sugs, sources_sugs = _generate_rag_based_advice(
            query=f"{node_label} 解決策",
            project_id=project_id,
            similar_cases_engine_id=SIMILAR_CASES_ENGINE_ID,
            suggestions_engine_id=SUGGESTIONS_ENGINE_ID,
            rag_type="suggestions"
        )
        
        # 3. フロントに返す情報を整形
        # ここでは簡潔にするため、Geminiの最終整形は省略し、
        # 構造化されたデータを返す。
        initial_summary = f"「{node_label}」についてですね。{internal_summary}"
        
        actions = []
        if external_summary_cases and "見つけることができませんでした" not in external_summary_cases:
            actions.append({
                "type": "similar_cases",
                "title": "似たような悩みを持つ人々の声",
                "content": external_summary_cases,
                "sources": sources_cases
            })
        if external_summary_sugs and "見つけることができませんでした" not in external_summary_sugs:
             actions.append({
                "type": "suggestions",
                "title": "専門家による具体的なアドバイス",
                "content": external_summary_sugs,
                "sources": sources_sugs
            })

        response_data = {
            "initialSummary": initial_summary,
            "actions": actions,
            "nodeId": data.get('nodeId', node_label), # nodeIdがあればそれを使う
            "nodeLabel": node_label
        }
        
        print(f"✅ Sending node tap response for '{node_label}'")
        return jsonify(response_data), 200

    except Exception as e:
        print(f"❌ Error in handle_node_tap: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to handle node tap"}), 500


@app.route('/analysis/chat', methods=['POST'])
def post_chat_message():
    user_record = _verify_token(request)
    # ★★★ 修正: 認証成功時はdict型、失敗時はResponseオブジェクトが返るため、dict型かどうかで判定する ★★★
    if not isinstance(user_record, dict):
        return user_record

    data = request.get_json()
    if not data:
        return jsonify({"error": "Invalid request: no data provided"}), 400

    chat_history = data.get('chat_history', [])
    message = data.get('message')
    use_rag = data.get('use_rag', False)
    rag_type = data.get('rag_type') # 'similar_cases' or 'suggestions'

    if not message:
        return jsonify({"error": "Invalid request: 'message' is required"}), 400

    try:
        user_id = user_record['uid']
        print(f"--- Received chat message from user: {user_id} ---")
        
        # 1. ユーザーの全セッションサマリーを取得
        session_summary_text = _get_all_insights_as_text(user_id)
        if not session_summary_text:
             # サマリーがない場合は、RAGを使わずに応答する
            ai_response_text = generate_chat_response("", chat_history, message)
            return jsonify({"response": ai_response_text, "sources": []})

        # 2. RAGを使用する場合、コンテキストを取得
        rag_context = ""
        sources = []
        if use_rag:
            print(f"--- Generating RAG context (type: {rag_type}) ---")
            rag_context, sources = _generate_rag_based_advice(
                query=f"ユーザー分析:\n{session_summary_text}\n\nユーザーの質問:\n{message}",
                project_id=project_id,
                similar_cases_engine_id=SIMILAR_CASES_ENGINE_ID,
                suggestions_engine_id=SUGGESTIONS_ENGINE_ID,
                rag_type=rag_type
            )
            print(f"✅ RAG context generated. Sources: {sources}")

        # 3. Geminiに最終的な応答を生成させる
        ai_response_text = generate_chat_response(session_summary_text, chat_history, message, rag_context)
        
        return jsonify({"response": ai_response_text, "sources": sources})

    except Exception as e:
        print(f"❌ Error in post_chat_message: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to process chat message"}), 500


@app.route('/home/suggestion_v2', methods=['GET'])
def get_home_suggestion_v2():
    """
    ユーザーの最新のベクトルに基づき、Vertex AI Vector Search を使って類似した過去の対話ノードを検索し、
    ホーム画面で新しい対話のきっかけを提案します。
    """
    user_record = _verify_token(request)
    # ★★★ 修正: 認証成功時はdict型、失敗時はResponseオブジェクトが返るため、dict型かどうかで判定する ★★★
    if not isinstance(user_record, dict):
        return user_record

    user_id = user_record['uid']
    print(f"--- Received home suggestion v2 request for user: {user_id} ---")

    # (★修正) Vector Search用のリージョン変数を明示的に取得
    vector_search_region = os.getenv('GCP_VERTEX_AI_REGION', 'asia-northeast1')


    # 環境変数が設定されているかチェック
    if not all([VECTOR_SEARCH_INDEX_ID, VECTOR_SEARCH_ENDPOINT_ID, VECTOR_SEARCH_DEPLOYED_INDEX_ID]):
        print("❌ ERROR: Vector Search environment variables are not set on the server.")
        return jsonify({"error": "Server configuration error for suggestions."}), 500

    try:
        # 1. ユーザーの最新のベクトルを取得
        query_ref = db_firestore.collection('vector_embeddings').where('user_id', '==', user_id).order_by('created_at', direction=firestore.Query.DESCENDING).limit(1)
        docs = list(query_ref.stream())

        if not docs:
            print(f"No vector embeddings found for user {user_id}.")
            return jsonify({}), 204 # 提案なし

        latest_doc = docs[0]
        latest_doc_data = latest_doc.to_dict()
        latest_embedding = latest_doc_data.get('embedding')
        
        if not latest_embedding:
            print(f"Embedding not found in the latest document for user {user_id}.")
            return jsonify({}), 204

        print(f"Found latest embedding for user {user_id}. Searching for neighbors...")

        # 2. Vertex AI Vector Search で近傍探索
        endpoint_resource_name = f"projects/{project_id}/locations/{vector_search_region}/indexEndpoints/{VECTOR_SEARCH_ENDPOINT_ID}"
        my_index_endpoint = aiplatform.MatchingEngineIndexEndpoint(index_endpoint_name=endpoint_resource_name)

        response = my_index_endpoint.find_neighbors(
            queries=[latest_embedding],
            num_neighbors=5, # 自分自身が含まれる可能性があるので多めに取得
            deployed_index_id=VECTOR_SEARCH_DEPLOYED_INDEX_ID
        )

        if not response or not response[0]:
             print("No similar nodes found from vector search.")
             return jsonify({}), 204

        # 3. 検索結果の処理
        # 自分自身のドキュメントIDを除外
        filtered_neighbors = [neighbor for neighbor in response[0] if neighbor.id != latest_doc.id]

        if not filtered_neighbors:
            print("No other similar nodes found after filtering.")
            return jsonify({}), 204

        # 4. 提案するノードを選択して詳細情報を取得
        # 最も類似度が高いものを選択
        suggestion_neighbor = filtered_neighbors[0]
        
        # Vector SearchのIDは `vector_embeddings` のドキュメントIDと一致する
        suggestion_ref = db_firestore.collection('vector_embeddings').document(suggestion_neighbor.id)
        suggestion_doc = suggestion_ref.get()

        if not suggestion_doc.exists:
            print(f"Suggested document {suggestion_neighbor.id} not found in Firestore.")
            return jsonify({}), 204

        suggestion_data = suggestion_doc.to_dict()
        node_label = suggestion_data.get('nodeLabel')
        node_id = suggestion_data.get('nodeId')

        if not node_label or not node_id:
            print(f"nodeLabel or nodeId missing in suggested document {suggestion_neighbor.id}.")
            return jsonify({}), 204

        # 5. フロントエンドに返すレスポンスを生成
        response_data = {
            "title": "過去の対話を振り返ってみませんか？",
            "subtitle": f"「{node_label}」について、新たな発見があるかもしれません。",
            "nodeId": node_id,
            "nodeLabel": node_label
        }
        print(f"✅ Sending suggestion v2: {response_data}")
        return jsonify(response_data), 200

    except Exception as e:
        print(f"❌ Error in get_home_suggestion_v2: {e}")
        traceback.print_exc()
        return jsonify({"error": "Failed to get home suggestion"}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 8080)), debug=True)