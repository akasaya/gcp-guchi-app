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

    vertex_ai_region = os.getenv('GCP_VERTEX_AI_REGION', 'us-central1')
    vertexai.init(project=project_id, location=vertex_ai_region)
    print(f"✅ Vertex AI initialized for project: {project_id} in {vertex_ai_region}")

    # RAG用設定 (2つのエンジンIDに対応)
    SIMILAR_CASES_ENGINE_ID = os.getenv('SIMILAR_CASES_ENGINE_ID')
    SUGGESTIONS_ENGINE_ID = os.getenv('SUGGESTIONS_ENGINE_ID')
    if 'K_SERVICE' in os.environ and (not SIMILAR_CASES_ENGINE_ID or not SUGGESTIONS_ENGINE_ID):
        print("⚠️ WARNING: One or both of SIMILAR_CASES_ENGINE_ID and SUGGESTIONS_ENGINE_ID environment variables are not set.")

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
# ★★★ 新規追加 ★★★
INTERNAL_CONTEXT_PROMPT_TEMPLATE = """
あなたは、ユーザーの過去のカウンセリング記録を要約するアシスタントです。
以下のセッション記録全体から、特定のキーワード「{keyword}」に関連する記述や、そこから推測されるユーザーの感情や葛藤を抜き出し、1〜2文の非常に簡潔な要約を作成してください。
要約は、ユーザーに「以前、この件についてこのようにお話しされていましたね」と自然に語りかける形式で記述してください。
キーワードに直接関連する記述が見つからない場合は、「このテーマについて、これまで具体的なお話はなかったようです。」と出力してください。

# セッション記録
{context}

# 要約:
"""

# ★★★ 新規追加 ★★★
# AIが能動的に提案を行うためのキーワードリスト
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

def generate_chat_response(session_summary, chat_history, user_message):
    history_str = "\n".join([f"{msg['author']}: {msg['text']}" for msg in chat_history])
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

# ★★★ 新規追加 ★★★
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

# ★★★ この関数を修正 ★★★
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

    # ★★★ ここからプロンプトを全面的に書き換えます ★★★
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

# --- バックグラウンド処理 (変更なし) ---
def _prefetch_questions_and_save(session_id: str, user_id: str, insights_md: str, current_turn: int, max_turns: int):
    # ... (この関数の中身は変更ありません)
    print(f"--- Triggered question prefetch for user: {user_id}, session: {session_id}, next_turn: {current_turn + 1} ---")
    if current_turn >= max_turns:
        print("Max turns reached. Skipping question prefetch.")
        return
    try:
        questions = generate_follow_up_questions(insights=insights_md)
        if not questions:
            print(f"⚠️ AI failed to generate prefetch questions for session {session_id}.")
            return
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        next_turn = current_turn + 1
        questions_collection = session_doc_ref.collection('questions')
        last_question_query = questions_collection.order_by('order', direction=firestore.Query.DESCENDING).limit(1).stream()
        last_order = next(last_question_query, None)
        start_order = last_order.to_dict().get('order', -1) + 1 if last_order else 0
        batch = db_firestore.batch()
        for i, q_data in enumerate(questions):
            if q_text := q_data.get("question_text"):
                q_doc_ref = questions_collection.document()
                batch.set(q_doc_ref, {'text': q_text, 'turn': next_turn, 'order': start_order + i, 'created_at': firestore.SERVER_TIMESTAMP, 'is_prefetched': True})
        batch.commit()
        print(f"✅ Successfully prefetched questions for turn {next_turn}.")
    except Exception as e:
        print(f"❌ Failed to prefetch questions for session {session_id}: {e}")
        traceback.print_exc()

def _update_graph_cache(user_id: str):
    # ... (この関数の中身は変更ありません)
    print(f"--- Triggered graph cache update for user: {user_id} ---")
    try:
        all_insights_text = _get_all_insights_as_text(user_id)
        if not all_insights_text: return
        raw_graph_data = generate_graph_data(all_insights_text)
        nodes = raw_graph_data.get('nodes', [])
        edges = raw_graph_data.get('edges', [])
        sanitized_nodes = [n for n in nodes if isinstance(n, dict) and n.get('id')]
        valid_node_ids = {n['id'] for n in sanitized_nodes}
        sanitized_edges = [e for e in edges if isinstance(e, dict) and e.get('source') in valid_node_ids and e.get('target') in valid_node_ids]
        final_graph_data = {"nodes": sanitized_nodes, "edges": sanitized_edges}
        cache_doc_ref = db_firestore.collection('users').document(user_id).collection('analysis').document('graph_cache')
        cache_doc_ref.set({'data': final_graph_data, 'updated_at': firestore.SERVER_TIMESTAMP})
        print(f"✅ Successfully updated graph cache for user: {user_id}")
    except Exception as e:
        print(f"❌ Failed to update graph cache for user {user_id}: {e}")
        traceback.print_exc()

# ===== 認証ヘルパー (変更なし) =====
def _verify_token(request):
    # ... (この関数の中身は変更ありません)
    auth_header = request.headers.get('Authorization', '')
    if not auth_header.startswith('Bearer '):
        raise auth.InvalidIdTokenError("Authorization token is missing or invalid")
    id_token = auth_header.split('Bearer ')[1]
    return auth.verify_id_token(id_token, clock_skew_seconds=15)

# ===== API Routes (変更・追加あり) =====
@app.route('/session/start', methods=['POST'])
def start_session():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        data = request.get_json()
        if not data or 'topic' not in data: return jsonify({'error': 'Topic is required'}), 400
        topic = data['topic']
        questions = generate_initial_questions(topic=topic) # <- この行を修正
        if not questions: raise Exception("AI failed to generate questions.")
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document()
        session_doc_ref.set({'topic': topic, 'status': 'in_progress', 'created_at': firestore.SERVER_TIMESTAMP, 'turn': 1, 'max_turns': 3})
        questions_collection = session_doc_ref.collection('questions')
        question_docs = []
        for i, q_data in enumerate(questions):
            if q_text := q_data.get("question_text"):
                q_doc_ref = questions_collection.document()
                q_doc_ref.set({'text': q_text, 'order': i, 'turn': 1})
                question_docs.append({'question_id': q_doc_ref.id, 'question_text': q_text})
        if not question_docs: raise Exception("All generated questions were empty.")
        return jsonify({'session_id': session_doc_ref.id, 'questions': question_docs}), 200
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in start_session: {e}")
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Error in start_session: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to start session', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/swipe', methods=['POST'])
def record_swipe(session_id):
    # ... (この関数の中身は変更ありません)
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        data = request.get_json()
        if not data: return jsonify({'error': 'Request body is missing'}), 400
        question_id = data.get('question_id')
        answer = data.get('answer') 
        hesitation_time = data.get('hesitation_time')
        speed = data.get('speed')
        turn = data.get('turn')
        if not all([question_id, turn is not None]) or not isinstance(answer, bool): return jsonify({'error': 'Missing or invalid type for required fields'}), 400
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        session_doc_ref.collection('swipes').add({'question_id': question_id,'answer': answer,'hesitation_time_sec': hesitation_time,'swipe_duration_ms': speed,'turn': turn,'timestamp': firestore.SERVER_TIMESTAMP})
        return jsonify({'status': 'swipe_recorded'}), 200
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in record_swipe: {e}")
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Error recording swipe: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to record swipe', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/summary', methods=['POST'])
def post_summary(session_id):
    # ... (この関数の中身は変更ありません)
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        data = request.get_json()
        if not data or 'swipes' not in data: return jsonify({'error': 'Swipes data is required'}), 400
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        session_doc = session_doc_ref.get()
        if not session_doc.exists: return jsonify({'error': 'Session not found'}), 404
        session_data = session_doc.to_dict()
        topic = session_data.get('topic', '不明')
        current_turn = session_data.get('turn', 1)
        max_turns = session_data.get('max_turns', 3)
        swipes_text = "\n".join([f"Q: {s.get('question_text')}\nA: {'はい' if s.get('answer') else 'いいえ'}" for s in data['swipes']])
        summary_data = generate_summary_only(topic=topic, swipes_text=swipes_text) # <- この行を修正
        insights_md = summary_data.get('insights')
        title = summary_data.get('title')
        if not insights_md or not title: raise Exception("AI failed to generate summary or title.")
        session_doc_ref.collection('analyses').add({'turn': current_turn, 'insights': insights_md, 'created_at': firestore.SERVER_TIMESTAMP})
        update_data = {'status': 'completed', 'updated_at': firestore.SERVER_TIMESTAMP, 'latest_insights': insights_md}
        if current_turn == 1: update_data['title'] = title
        session_doc_ref.update(update_data)
        threading.Thread(target=_update_graph_cache, args=(user_id,)).start()
        threading.Thread(target=_prefetch_questions_and_save, args=(session_id, user_id, insights_md, current_turn, max_turns)).start()
        print("--- Started background threads for graph cache and question prefetch. ---")
        return jsonify({'title': title, 'insights': insights_md, 'turn': current_turn, 'max_turns': max_turns}), 200
    except Exception as e:
        print(f"Error in post_summary: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to generate summary', 'details': str(e)}), 500

@app.route('/session/<string:session_id>/continue', methods=['POST'])
def continue_session(session_id):
    # ... (この関数の中身は変更ありません)
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        session_doc_ref = db_firestore.collection('users').document(user_id).collection('sessions').document(session_id)
        @firestore.transactional
        def update_turn(transaction, ref):
            snapshot = ref.get(transaction=transaction)
            if not snapshot.exists: raise Exception("Session not found")
            data = snapshot.to_dict()
            if data.get('turn', 1) >= data.get('max_turns', 3): raise Exception("Max turns reached.")
            new_turn = data.get('turn', 1) + 1
            transaction.update(ref, {'status': 'in_progress', 'turn': new_turn, 'updated_at': firestore.SERVER_TIMESTAMP})
            return new_turn
        transaction = db_firestore.transaction()
        new_turn = update_turn(transaction, session_doc_ref)
        questions_collection = session_doc_ref.collection('questions')
        query = questions_collection.where('turn', '==', new_turn).order_by('order')
        question_docs = [{'question_id': doc.id, 'question_text': doc.to_dict().get('text')} for doc in query.stream()]
        if not question_docs:
            print(f"⚠️ Prefetched questions not found for turn {new_turn}. Generating and SAVING now (fallback).")
            last_analysis_doc = next(session_doc_ref.collection('analyses').order_by('created_at', direction=firestore.Query.DESCENDING).limit(1).stream(), None)
            if not last_analysis_doc: raise Exception("Cannot generate fallback questions: no analysis found.")
            fallback_questions = generate_follow_up_questions(last_analysis_doc.to_dict().get('insights'))
            if not fallback_questions: raise Exception("AI failed to generate fallback questions.")
            last_question_query = questions_collection.order_by('order', direction=firestore.Query.DESCENDING).limit(1).stream()
            last_order = next(last_question_query, None)
            start_order = last_order.to_dict().get('order', -1) + 1 if last_order else 0
            batch = db_firestore.batch()
            for i, q_data in enumerate(fallback_questions):
                if q_text := q_data.get("question_text"):
                    q_doc_ref = questions_collection.document()
                    batch.set(q_doc_ref, {'text': q_text,'turn': new_turn,'order': start_order + i,'created_at': firestore.SERVER_TIMESTAMP,'is_prefetched': False})
                    question_docs.append({'question_id': q_doc_ref.id,'question_text': q_text})
            batch.commit()
            print(f"✅ Saved {len(fallback_questions)} fallback questions to Firestore.")
        if not question_docs: raise Exception("Failed to get any questions for the user.")
        return jsonify({'session_id': session_id, 'questions': question_docs, 'turn': new_turn}), 200
    except Exception as e:
        print(f"Error in continue_session: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to continue session', 'details': str(e)}), 500

# --- 分析系API ---
def _get_all_insights_as_text(user_id: str) -> str:
    # ... (この関数の中身は変更ありません)
    if not db_firestore: return ""
    sessions_ref = db_firestore.collection('users').document(user_id).collection('sessions').order_by('created_at').limit_to_last(20)
    sessions = sessions_ref.get() 
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
            print(f"Skipping potentially corrupted session {session.id} for insight aggregation due to error: {inner_e}")
            continue
    return "".join(all_insights)

@app.route('/analysis/graph', methods=['GET'])
def get_analysis_graph():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        graph_data = _get_graph_from_cache_or_generate(user_id)
        return jsonify(graph_data)
    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in get_analysis_graph: {e}")
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Error getting analysis graph: {e}")
        traceback.print_exc()
        return jsonify({'error': 'Failed to get analysis graph', 'details': str(e)}), 500

def _get_graph_from_cache_or_generate(user_id: str):
    cache_doc_ref = db_firestore.collection('users').document(user_id).collection('analysis').document('graph_cache')
    cache_doc = cache_doc_ref.get()
    if cache_doc.exists:
        print(f"✅ Found graph cache for user {user_id}. Returning cached data.")
        return cache_doc.to_dict().get('data', {"nodes": [], "edges": []})
    
    print(f"⚠️ Graph cache not found for user {user_id}. Generating a new one...")
    all_insights_text = _get_all_insights_as_text(user_id)
    if not all_insights_text:
        print("No insights found to generate a graph.")
        return {"nodes": [], "edges": []}
    
    raw_graph_data = generate_graph_data(all_insights_text)
    
    nodes = raw_graph_data.get('nodes', [])
    edges = raw_graph_data.get('edges', [])
    sanitized_nodes = [n for n in nodes if isinstance(n, dict) and n.get('id')]
    valid_node_ids = {n['id'] for n in sanitized_nodes}
    sanitized_edges = [e for e in edges if isinstance(e, dict) and e.get('source') in valid_node_ids and e.get('target') in valid_node_ids]

    final_graph_data = {"nodes": sanitized_nodes, "edges": sanitized_edges}
    cache_doc_ref.set({'data': final_graph_data, 'updated_at': firestore.SERVER_TIMESTAMP})
    print(f"✅ Successfully generated and cached graph for user: {user_id}")
    return final_graph_data

@app.route('/home/suggestion', methods=['GET'])
def get_home_suggestion():
    """
    ホーム画面に表示するための、パーソナライズされた単一の提案を返す。
    ユーザーの過去の分析結果全体から、特に注意を引くべきキーワードを探して返す。
    """
    try:
        user = _verify_token(request)
        user_id = user['uid']
        print(f"--- Getting home suggestion for user: {user_id} ---")

        # ユーザーの全セッションの要約テキストを取得
        all_insights_text = _get_all_insights_as_text(user_id)

        if not all_insights_text:
            print("No insights found, no suggestion will be returned.")
            return jsonify({}), 204 # ユーザーデータがなければ提案なし

        # 事前に定義したキーワードリストと照合する
        found_keyword = None
        for keyword in PROACTIVE_KEYWORDS:
            # 単語として完全に一致する場合のみヒットさせる (例: "不安" は "不安感" にはヒットしない)
            if re.search(r'\b' + re.escape(keyword) + r'\b', all_insights_text, re.IGNORECASE):
                found_keyword = keyword
                print(f"Found proactive keyword for home suggestion: '{found_keyword}'")
                break # 最初に見つかったキーワードを提案として採用

        if found_keyword:
            # フロントエンドの HomeSuggestion モデルに合わせた形式でレスポンスを構築
            response_data = {
                "title": "AIからの提案",
                "subtitle": f"最近「{found_keyword}」について考えているようですね。思考を整理しませんか？",
                "node_id": found_keyword,
                "node_label": found_keyword
            }
            return jsonify(response_data), 200
        else:
            print("No relevant keywords found in insights for home suggestion.")
            return jsonify({}), 204 # 提案すべきキーワードが見つからなければ「提案なし」で返す

    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        # 認証エラーはフロント側で再ログインを促せるよう403を返す
        print(f"Auth Error in get_home_suggestion: {e}")
        return jsonify({'error': 'Invalid or expired token'}), 403
    except Exception as e:
        print(f"❌ Error in get_home_suggestion: {e}")
        traceback.print_exc()
        return jsonify({"error": "An internal error occurred while generating a suggestion."}), 500

@app.route('/analysis/proactive_suggestion', methods=['GET'])
def get_proactive_suggestion():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']

        print(f"--- Checking for proactive suggestion for user {user_id} ---")
        
        session_summary = _get_all_insights_as_text(user_id)
        if not session_summary:
            return jsonify(None) # 履歴がなければ何も返さない

        found_keyword = None
        for keyword in PROACTIVE_KEYWORDS:
            if keyword in session_summary:
                found_keyword = keyword
                print(f"✅ Found proactive keyword: '{found_keyword}'")
                break
        
        if not found_keyword:
            print("--- No proactive keyword found. ---")
            return jsonify(None) # キーワードが見つからなければ何も返さない

        # キーワードが見つかった場合、それに関する過去の文脈を要約
        context_summary = _summarize_internal_context(session_summary, found_keyword)

        suggestion_text = (
            f"これまでのセッションで、特に「{found_keyword}」について触れられていることが多いようです。\n"
            f"{context_summary}\n"
            "よろしければ、このテーマについてもう少し深く掘り下げてみませんか？"
        )

        response_data = {
            "initial_summary": suggestion_text,
            "node_label": found_keyword,
            "actions": [
                {"id": "talk_freely", "label": "このテーマについて話す"},
                {"id": "get_similar_cases", "label": "似た悩みの話を聞く"},
                {"id": "get_suggestions", "label": "具体的な対策を見る"}
            ]
        }
        return jsonify(response_data)

    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in get_proactive_suggestion: {e}")
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Error in get_proactive_suggestion: {e}")
        traceback.print_exc()
        return jsonify({"error": "An internal error occurred."}), 500


# ★★★ 新規追加 ★★★
@app.route('/chat/node_tap', methods=['POST'])
def handle_node_tap():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        data = request.get_json()
        if not data or not (node_label := data.get('node_label')):
            return jsonify({'error': 'node_label is required'}), 400

        print(f"--- Node tap received for user {user_id}, node: '{node_label}' ---")

        session_summary = _get_all_insights_as_text(user_id)
        initial_summary = _summarize_internal_context(session_summary, node_label)
        
        response_data = {
            "initial_summary": f"「{node_label}」についてですね。\n{initial_summary}",
            "node_label": node_label, # フロントが後で使うためにラベルを返す
            "actions": [
                {"id": "talk_freely", "label": "自分の考えを話す"},
                {"id": "get_similar_cases", "label": "似たような悩みの人の話を聞く"},
                {"id": "get_suggestions", "label": "具体的な対策やヒントを見る"}
            ]
        }
        return jsonify(response_data)

    except (auth.InvalidIdTokenError, IndexError, ValueError) as e:
        print(f"Auth Error in handle_node_tap: {e}")
        return jsonify({'error': 'Invalid or expired token', 'details': str(e)}), 403
    except Exception as e:
        print(f"Error in handle_node_tap: {e}")
        traceback.print_exc()
        return jsonify({"error": "An internal error occurred."}), 500

# ★★★ この関数を修正 ★★★
@app.route('/analysis/chat', methods=['POST'])
def post_chat_message():
    try:
        decoded_token = _verify_token(request)
        user_id = decoded_token['uid']
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request body is missing'}), 400

        user_message = data.get('message')
        use_rag = data.get('use_rag', False)
        rag_type = data.get('rag_type', None) # RAGの種別を取得

        if not user_message and not use_rag:
            return jsonify({'error': 'message or use_rag flag is required'}), 400

        session_summary = _get_all_insights_as_text(user_id)
        ai_response = ""
        sources = []

        if not session_summary:
            ai_response = "こんにちは。分析できるセッション履歴がまだないようです。まずはセッションを完了して、ご自身の内面を探る旅を始めてみましょう。"

        elif use_rag:
            print(f"--- RAG advice triggered via chat API flag (type: {rag_type}) ---")
            # RAGの呼び出しに `rag_type` を渡す
            ai_response, sources = _generate_rag_based_advice(
                session_summary,
                project_id,
                SIMILAR_CASES_ENGINE_ID,
                SUGGESTIONS_ENGINE_ID,
                rag_type=rag_type
            )
        else:
            ai_response = generate_chat_response(session_summary, data.get('chat_history', []), user_message)

        return jsonify({'answer': ai_response, 'sources': sources})
    except Exception as e:
        print(f"Error in post_chat_message: {e}")
        traceback.print_exc()
        return jsonify({"error": "An internal error occurred."}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)