import os
import uuid
import subprocess
from google.cloud import aiplatform, storage

def get_gcloud_project():
    """gcloud configからプロジェクトIDを取得するヘルパー関数"""
    try:
        project_id_bytes = subprocess.check_output(
            ["gcloud", "config", "get-value", "project"],
            stderr=subprocess.PIPE
        )
        project_id = project_id_bytes.strip().decode("utf-8")
        # gcloudが設定されていない場合 '(unset)' が返る
        if project_id == "(unset)":
            return None
        return project_id
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

# --- 設定項目 ---
# gcloud configからプロジェクトIDを取得。設定されていない場合はエラー。
PROJECT_ID = get_gcloud_project()
if not PROJECT_ID:
    raise ValueError(
        "GCPプロジェクトIDを取得できませんでした。"
        " 'gcloud config set project YOUR_PROJECT_ID' を実行してプロジェクトを設定してください。"
    )

# 作成するリソースのリージョンと表示名
REGION = "asia-northeast1" # 東京リージョン
INDEX_DISPLAY_NAME = "guchiswipe-node-index"
ENDPOINT_DISPLAY_NAME = "guchiswipe-node-endpoint"
# デプロイする際のID
DEPLOYED_INDEX_ID_PREFIX = "guchiswipe_deployed"

# ベクトルストアのGCSバケット（Index作成に必要）
BUCKET_NAME = f"{PROJECT_ID}-guchiswipe-vs-store"
BUCKET_URI = f"gs://{BUCKET_NAME}"

# ベクトルの次元数 (text-multilingual-embedding-002 は 768次元)
DIMENSIONS = 768
# --- 設定項目ここまで ---

def setup_vector_search():
    """Vertex AI Vector Search のインデックスとエンドポイントを作成・デプロイする"""
    print(f"Project: {PROJECT_ID}, Region: {REGION}")

    # GCSバケットの存在確認と作成
    storage_client = storage.Client(project=PROJECT_ID)
    bucket = storage_client.lookup_bucket(BUCKET_NAME)
    if bucket is None:
        print(f"Creating GCS bucket: {BUCKET_NAME}...")
        storage_client.create_bucket(BUCKET_NAME, location=REGION)
        print("✅ Bucket created.")
    else:
        print(f"Bucket {BUCKET_NAME} already exists.")
        
    aiplatform.init(project=PROJECT_ID, location=REGION, staging_bucket=BUCKET_URI)

    # 1. インデックスの作成
    print(f"\n--- 1. Checking/Creating Index: {INDEX_DISPLAY_NAME} ---")
    existing_indexes = aiplatform.MatchingEngineIndex.list(
        filter=f'display_name="{INDEX_DISPLAY_NAME}"'
    )
    if existing_indexes:
        index = existing_indexes[0]
        print(f"✅ Index already exists: {index.resource_name}")
    else:
        print("Creating new index...")
        index = aiplatform.MatchingEngineIndex.create_tree_ah_index(
            display_name=INDEX_DISPLAY_NAME,
            dimensions=DIMENSIONS,
            approximate_neighbors_count=10,
            distance_measure_type="DOT_PRODUCT_DISTANCE",
            index_update_method="STREAM_UPDATE", # リアルタイム更新用
            description="Index for GuchiSwipe user conversation nodes."
        )
        print(f"✅ Index created successfully: {index.resource_name}")

    # 2. エンドポイントの作成
    print(f"\n--- 2. Checking/Creating Endpoint: {ENDPOINT_DISPLAY_NAME} ---")
    existing_endpoints = aiplatform.MatchingEngineIndexEndpoint.list(
        filter=f'display_name="{ENDPOINT_DISPLAY_NAME}"'
    )
    if existing_endpoints:
        endpoint = existing_endpoints[0]
        print(f"✅ Endpoint already exists: {endpoint.resource_name}")
    else:
        print("Creating new endpoint...")
        endpoint = aiplatform.MatchingEngineIndexEndpoint.create(
            display_name=ENDPOINT_DISPLAY_NAME,
            public_endpoint_enabled=True,
            description="Endpoint for GuchiSwipe node index."
        )
        print(f"✅ Endpoint created successfully: {endpoint.resource_name}")

    # 3. インデックスをエンドポイントにデプロイ
    print(f"\n--- 3. Checking/Deploying Index to Endpoint ---")
    # すでに同じインデックスがデプロイされているか確認
    deployed_index_id_obj = next(
        (d for d in endpoint.deployed_indexes if d.index == index.resource_name), 
        None
    )

    if deployed_index_id_obj:
        deployed_id = deployed_index_id_obj.id
        print(f"✅ Index '{index.display_name}' is already deployed to endpoint '{endpoint.display_name}' with Deployed ID: {deployed_id}.")
    else:
        # デプロイIDはユニークにする必要がある
        deployed_id = f"{DEPLOYED_INDEX_ID_PREFIX}_{str(uuid.uuid4())[:8]}"
        print(f"Deploying index with Deployed ID: {deployed_id}... (This may take up to 30 minutes)")
        endpoint.deploy_index(
            index=index,
            deployed_index_id=deployed_id
        )
        print(f"✅ Index deployed successfully.")

    # 4. 必要な情報を出力
    print("\n--- 🚀 Setup Complete! ---")
    print("Please set the following environment variables in your Cloud Run service:")
    print("-" * 60)
    print(f"VECTOR_SEARCH_INDEX_ID={index.name}")
    print(f"VECTOR_SEARCH_ENDPOINT_ID={endpoint.name}")
    print(f"VECTOR_SEARCH_DEPLOYED_INDEX_ID={deployed_id}")
    print(f"GCP_VERTEX_AI_REGION={REGION}")
    print("-" * 60)

if __name__ == "__main__":
    setup_vector_search()
