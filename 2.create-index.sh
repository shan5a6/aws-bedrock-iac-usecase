#!/bin/bash
set -e
 
INDEX="iac-rag11-prod-vec" # replace with your index name
ENDPOINT="https://dlaap8pnajzhwo4og5z3.us-east-1.aoss.amazonaws.com" # you have to replace with your AOSS url
REGION="us-east-1"
 
echo "🔍 Checking if index [$INDEX] exists..."
if awscurl --service aoss --region $REGION -X GET "$ENDPOINT/_cat/indices?v" | grep -q $INDEX; then
  echo "⚠️  Index [$INDEX] exists. Deleting..."
  awscurl --service aoss --region $REGION -X DELETE "$ENDPOINT/$INDEX"
  echo "✅ Deleted index [$INDEX]."
else
  echo "ℹ️  Index [$INDEX] not found. Skipping delete."
fi
 
echo "🚀 Creating index [$INDEX] with KNN mapping..."
awscurl --service aoss --region $REGION \
  -X PUT "$ENDPOINT/$INDEX" \
  -H "Content-Type: application/json" \
  -d '{
    "settings": {
      "index": {
        "knn": true,
        "knn.algo_param.ef_search": 256
      }
    },
    "mappings": {
      "properties": {
        "doc_id":        { "type": "keyword" },
        "module_name":   { "type": "keyword" },
        "version":       { "type": "keyword" },
        "path":          { "type": "keyword" },
        "block_type":    { "type": "keyword" },
        "provider":      { "type": "keyword" },
        "services":      { "type": "keyword" },
        "inputs":        { "type": "keyword" },
        "outputs":       { "type": "keyword" },
        "tags":          { "type": "keyword" },
        "owners":        { "type": "keyword" },
        "maturity":      { "type": "keyword" },
        "region_allowed":{ "type": "keyword" },
        "commit_sha":    { "type": "keyword" },
        "text":          { "type": "text"    },
        "code":          { "type": "text"    },
        "vector":        { "type": "knn_vector", "dimension": 1024 }
      }
    }
  }'
 
echo "✅ Index [$INDEX] created successfully!"
 
echo "🔎 Verifying mapping..."
awscurl --service aoss --region $REGION -X GET "$ENDPOINT/$INDEX/_mapping" | jq .
