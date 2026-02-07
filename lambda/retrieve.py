import os
import json
import re
import time
from typing import Any, Dict, List, Tuple

import boto3
from botocore.exceptions import ClientError
from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

# ========= Env & Config =========
AWS_REGION            = os.getenv("CORE_REGION", os.getenv("AWS_REGION", "us-east-1"))
AOSS_HOST             = os.getenv("AOSS_HOST","dlaap8pnajzhwo4og5z3.us-east-1.aoss.amazonaws.com")                              # e.g. "xxx.us-east-1.aoss.amazonaws.com"
AOSS_INDEX            = os.getenv("AOSS_INDEX", "iac-rag11-prod-vec")
AOSS_KNN_DIM          = int(os.getenv("AOSS_KNN_DIM", "1024"))
KNN_K                 = int(os.getenv("KNN_K", "100"))
BM25_SIZE             = int(os.getenv("BM25_SIZE", "100"))
RRF_K                 = int(os.getenv("RRF_K", "60"))
TOP_K_DEFAULT         = int(os.getenv("TOP_K", "20"))

BEDROCK_REGION        = os.getenv("BEDROCK_REGION", AWS_REGION)
BEDROCK_EMBED_MODEL   = os.getenv("BEDROCK_EMBED_MODEL", "amazon.titan-embed-text-v2:0")
EMBED_MAX_CHARS       = int(os.getenv("EMBED_MAX_CHARS", "8000"))

DDB_TABLE             = os.getenv("DDB_TABLE", "tf_module_catalog")
POLICY_PARAM_NAME     = os.getenv("POLICY_PARAM_NAME", "/${local.name_prefix}/org-policy")
POLICY_S3_URI         = os.getenv("POLICY_S3_URI", "")  # optional s3://bucket/key.json

LOG_LEVEL             = os.getenv("LOG_LEVEL", "INFO")

# Optional (handy for debugging Phase-1 endpoints; not strictly required for calls)
VPC_ENDPOINT_AOSS     = os.getenv("VPC_ENDPOINT_AOSS", "vpce-001fabc7bc51d39ed")
VPC_ENDPOINT_BEDROCK  = os.getenv("VPC_ENDPOINT_BEDROCK", "vpce-0f3acb1ba63369f67")
VPC_ENDPOINT_DDB      = os.getenv("VPC_ENDPOINT_DDB", "vpce-07d61b2fee4a3b196")
VPC_ENDPOINT_S3       = os.getenv("VPC_ENDPOINT_S3", "vpce-0898502c8507e0b26")

STOPWORDS = set("a an and or the of for to from with in on at by is are be have has need needs want wants into".split())

# ========= AWS Clients (module scope for connection reuse) =========
_session      = boto3.Session(region_name=AWS_REGION)
_credentials  = _session.get_credentials()
_aoss_auth    = AWSV4SignerAuth(_credentials, AWS_REGION, service='aoss')

aoss = OpenSearch(
    hosts=[{'host': AOSS_HOST, 'port': 443}],
    http_auth=_aoss_auth,
    use_ssl=True,
    verify_certs=True,
    connection_class=RequestsHttpConnection,
    timeout=3,
    max_retries=2,
    retry_on_timeout=True
)

bedrock = boto3.client('bedrock-runtime', region_name=BEDROCK_REGION)
ddb     = boto3.resource('dynamodb', region_name=AWS_REGION).Table(DDB_TABLE)
ssm     = boto3.client('ssm', region_name=AWS_REGION)
s3      = boto3.client('s3', region_name=AWS_REGION)

# ========= Helpers =========
def _log(msg: str, **fields):
    if LOG_LEVEL.upper() in ("DEBUG", "INFO"):
        print(json.dumps({"msg": msg, **fields}))

def _embed_text(txt: str) -> List[float]:
    txt = txt[:EMBED_MAX_CHARS]
    body = {"inputText": txt}
    resp = bedrock.invoke_model(
        modelId=BEDROCK_EMBED_MODEL,
        contentType='application/json',
        accept='application/json',
        body=json.dumps(body)
    )
    payload = json.loads(resp['body'].read())
    return payload.get("embedding", [])

def _keywordize(ask: str) -> str:
    tokens = re.findall(r"[a-zA-Z0-9_+-]+", ask.lower())
    terms  = [t for t in tokens if t not in STOPWORDS and len(t) > 1]
    return " ".join(terms) or ask

def _build_filter(constraints: Dict[str, Any]) -> Dict[str, Any]:
    must = [
        {"term": {"provider": "aws"}},
        {"term": {"maturity": "stable"}}
    ]
    if constraints.get("approved_only", True):
        must.append({"term": {"approved": True}})
    region = (constraints or {}).get("region")
    if region:
        must.append({"term": {"region_allowed": region}})
    return {"bool": {"must": must}}

def _search_knn(embedding: List[float], constraints: Dict[str, Any]) -> List[Dict[str, Any]]:
    body = {
        "size": KNN_K,
        "query": {
            "knn": {
                "vector": {
                    "vector": embedding,
                    "k": KNN_K,
                    # "filter": _build_filter(constraints)  # Not supported in AOSS knn query
                }
            }
        }
    }
    res = aoss.search(index=AOSS_INDEX, body=body)
    return res.get("hits", {}).get("hits", [])

def _search_bm25(terms: str, constraints: Dict[str, Any]) -> List[Dict[str, Any]]:
    body = {
        "size": BM25_SIZE,
        "query": {
            "bool": {
                "must": [
                    {"multi_match": {
                        "query": terms,
                        "fields": ["text^3", "code"],
                        "operator": "and"
                    }}
                ],
                "filter": _build_filter(constraints)
            }
        }
    }
    res = aoss.search(index=AOSS_INDEX, body=body)
    return res.get("hits", {}).get("hits", [])

def _block_priority(bt: str) -> int:
    if not bt: return 0
    bt = bt.lower()
    if bt in ("readme","example","usage"): return 3
    if bt in ("variable","output"): return 2
    if bt in ("resource","module"): return 1
    return 0

def _is_preferable(a: Dict[str, Any], b: Dict[str, Any]) -> bool:
    return _block_priority(a.get("block_type")) > _block_priority(b.get("block_type"))

def _rrf_merge(knn_hits: List[Dict[str, Any]], bm25_hits: List[Dict[str, Any]]) -> List[Tuple[str, Dict[str, Any], float]]:
    def pos_map(hits): return {h["_id"]: i for i, h in enumerate(hits)}
    pos_knn  = pos_map(knn_hits)
    pos_bm25 = pos_map(bm25_hits)

    doc_ids = set(pos_knn) | set(pos_bm25)
    fused = []
    for doc_id in doc_ids:
        score = 0.0
        if doc_id in pos_knn:  score += 1.0 / (RRF_K + (pos_knn[doc_id] + 1))
        if doc_id in pos_bm25: score += 1.0 / (RRF_K + (pos_bm25[doc_id] + 1))
        # pick representative hit (prefer README/example)
        rep = None
        if doc_id in pos_knn:
            rep = knn_hits[pos_knn[doc_id]]
        if doc_id in pos_bm25:
            cand = bm25_hits[pos_bm25[doc_id]]
            if _is_preferable(cand.get("_source", {}), (rep or {}).get("_source", {})):
                rep = cand
        fused.append((doc_id, rep, score))

    fused.sort(key=lambda x: x[2], reverse=True)
    # De-duplicate by module_name/version/path
    seen = set()
    winners = []
    for doc_id, hit, score in fused:
        src = hit.get("_source", {})
        dedupe = (src.get("module_name"), src.get("version"), src.get("path"))
        if dedupe in seen:
            continue
        seen.add(dedupe)
        if _block_priority(src.get("block_type")) > 0:
            score += 0.05
        winners.append((doc_id, hit, score))
    return winners

def _to_chunk(hit: Dict[str, Any], score: float) -> Dict[str, Any]:
    src = hit.get("_source", {})
    return {
        "doc_id": src.get("doc_id"),
        "module_name": src.get("module_name"),
        "version": src.get("version"),
        "path": src.get("path"),
        "block_type": src.get("block_type"),
        "score": round(float(score), 4),
        "text": (src.get("text") or "")[:12000],
        "code": (src.get("code") or "")[:12000]
    }

def _catalog_for(module_name: str, version: str) -> Dict[str, Any]:
    from boto3.dynamodb.conditions import Key
    pk = f"MOD#{module_name}"
    prefix = f"VER#{version}#PATH#"
    items, last = [], None
    while True:
        params = {
            "KeyConditionExpression": Key("pk").eq(pk) & Key("sk").begins_with(prefix),
        }
        if last: params["ExclusiveStartKey"] = last
        resp = ddb.query(**params)
        items.extend(resp.get("Items", []))
        last = resp.get("LastEvaluatedKey")
        if not last: break

    inputs, outputs, tags = set(), set(), set()
    maturity = None
    for it in items:
        for i in it.get("inputs", []): inputs.add(i)
        for o in it.get("outputs", []): outputs.add(o)
        for t in it.get("tags", []): tags.add(t)
        if not maturity and it.get("maturity"): maturity = it["maturity"]

    return {
        "module_name": module_name,
        "version": version,
        "inputs": sorted(inputs),
        "outputs": sorted(outputs),
        "tags": sorted(tags),
        "maturity": maturity or "stable"
    }

def _get_org_policy() -> Dict[str, Any]:
    # Prefer SSM parameter; fallback to S3 JSON; else empty.
    try:
        resp = ssm.get_parameter(Name=POLICY_PARAM_NAME)
        if "Parameter" in resp:
            return json.loads(resp["Parameter"]["Value"])
    except Exception:
        pass

    if POLICY_S3_URI.startswith("s3://"):
        _, _, rest = POLICY_S3_URI.partition("s3://")
        bucket, _, key = rest.partition("/")
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            return json.loads(obj["Body"].read().decode("utf-8"))
        except Exception:
            pass

    return {}

# ========= Lambda Handler =========
def handler(event, context):
    """
    Input:
    {
      "ask": "Need VPC with 3 private subnets and NAT",
      "constraints": {"region":"us-east-1","env":"dev","name_prefix":"teamx"},
      "top_k": 15
    }
    """
    t0 = time.time()
    ask = (event or {}).get("ask", "")
    if not ask.strip():
        return {"statusCode": 400, "body": json.dumps({"error": "ask is required"})}

    constraints = (event or {}).get("constraints", {}) or {}
    top_k = int((event or {}).get("top_k") or TOP_K_DEFAULT)

    # a) Embed ask
    embedding = _embed_text(ask)

    # b) kNN + filters
    knn_hits = _search_knn(embedding, constraints)

    # c) BM25
    ask_terms = _keywordize(ask)
    bm25_hits = _search_bm25(ask_terms, constraints)

    # d) RRF + de-dup + prioritize README/example
    fused = _rrf_merge(knn_hits, bm25_hits)
    chosen = fused[:top_k]
    chunks = [_to_chunk(hit, score) for _doc_id, hit, score in chosen]

    # e) Catalog roll-up per module/version
    modvers = sorted({(c["module_name"], c["version"]) for c in chunks if c.get("module_name") and c.get("version")})
    catalog = [_catalog_for(m, v) for (m, v) in modvers]

    # f) Org policy
    policy = _get_org_policy()

    latency_ms = round((time.time() - t0) * 1000, 1)
    _log("retrieve_done", latency_ms=latency_ms, modvers=len(modvers), chunks=len(chunks))

    resp = {
        "top_k_chunks": chunks,
        "catalog_summary": catalog,
        "org_policy": policy,
        "debug": {
            "ask_terms": ask_terms,
            "latency_ms": latency_ms,
            "counts": {
                "knn_hits": len(knn_hits),
                "bm25_hits": len(bm25_hits),
                "fused": len(fused),
                "returned": len(chunks)
            },
            "vpce": {
                "aoss": VPC_ENDPOINT_AOSS,
                "bedrock": VPC_ENDPOINT_BEDROCK,
                "ddb": VPC_ENDPOINT_DDB,
                "s3": VPC_ENDPOINT_S3
            }
        }
    }
    return {"statusCode": 200, "body": json.dumps(resp)}

