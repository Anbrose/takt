#!/usr/bin/env bash
# 创建录音笔记用的 GCS bucket，并给 Cloud Run 默认服务账号授权。可重复运行。
#   GCP_PROJECT=my-project ./scripts/notes-bucket.sh
# 可选：REGION（默认 australia-southeast1）、BUCKET（默认 ${GCP_PROJECT}-takt-notes）
set -euo pipefail

: "${GCP_PROJECT:?set GCP_PROJECT}"
REGION="${REGION:-australia-southeast1}"
BUCKET="${BUCKET:-${GCP_PROJECT}-takt-notes}"

gc() { gcloud --project "$GCP_PROJECT" "$@"; }

gc services enable \
  storage.googleapis.com \
  iamcredentials.googleapis.com \
  aiplatform.googleapis.com

if ! gc storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
  gc storage buckets create "gs://$BUCKET" \
    --location "$REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

# Cloud Run 默认服务账号：读写录音，并给自己签 v4 URL
PROJECT_NUMBER="$(gc projects describe "$GCP_PROJECT" --format='value(projectNumber)')"
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gc storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member "serviceAccount:$SA" \
  --role roles/storage.objectAdmin >/dev/null

gc iam service-accounts add-iam-policy-binding "$SA" \
  --member "serviceAccount:$SA" \
  --role roles/iam.serviceAccountTokenCreator >/dev/null

echo "NOTES_BUCKET=$BUCKET"
