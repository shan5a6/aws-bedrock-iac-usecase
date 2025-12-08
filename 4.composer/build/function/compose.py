import boto3
import json
import re
import os
import shutil
import uuid

# Initialize clients
lambda_client = boto3.client("lambda")
ssm = boto3.client("ssm")
bedrock = boto3.client("bedrock-runtime")
s3 = boto3.client("s3")

# Environment variables (set in Lambda console or SAM template)
ARTIFACTS_BUCKET = os.environ.get("ARTIFACTS_BUCKET", "iac-rag2-prod-artifacts")
BEDROCK_MODEL_ID = os.environ.get(
    "BEDROCK_MODEL_ID",
    "anthropic.claude-3-5-sonnet-20240620-v1:0"
)

def call_retriever(ask: str, constraints: dict):
    """Invoke retriever lambda and return parsed response"""
    response = lambda_client.invoke(
        FunctionName="iac-rag2-prod-retrieve-v2",
        Payload=json.dumps({"ask": ask, "constraints": constraints})
    )
    payload = response["Payload"].read()
    raw = json.loads(payload)

    if "body" in raw:
        try:
            raw["body"] = json.loads(raw["body"])
        except Exception:
            pass

    return raw


def load_org_policy():
    """Load org policy JSON from SSM parameter store"""
    param = ssm.get_parameter(Name="/iac-rag2-prod/org-policy", WithDecryption=True)
    return json.loads(param["Parameter"]["Value"])


def determine_requested_modules(ask: str, allowed_modules: list):
    """Determine requested modules from ask and warn about unsupported modules"""
    ask_words = set(re.findall(r"\b\w+\b", ask.lower()))
    requested, unsupported = [], []

    for word in ask_words:
        if word in allowed_modules:
            requested.append(word)
        else:
            unsupported.append(word)

    if unsupported:
        print(f"Warning: Unsupported modules requested: {unsupported}")

    return requested


def filter_chunks_by_module_path(chunks: list, requested_modules: list):
    """Filter retriever chunks by module paths"""
    filtered = []
    for ch in chunks:
        path = ch.get("path", "").lower()
        if any(f"/{mod}/" in path for mod in requested_modules):
            filtered.append(ch)
    return filtered


def policy_enforcer(chunks, org_policy):
    """Check retriever chunks against org policy"""
    allowed_services = set(org_policy.get("allowed_services", []))
    allowed_regions = set(org_policy.get("allowed_regions", []))
    deny_list = set(org_policy.get("deny_list", []))
    default_versions = org_policy.get("default_module_versions", {})
    required_tags = set(org_policy.get("required_tags", []))

    filtered_chunks = []
    for ch in chunks:
        code = ch.get("code", "")
        module = ch.get("module_name", "")
        compliant, issues = True, []

        if not any(svc in code for svc in allowed_services):
            issues.append("Service not in allowed_services")
            compliant = False

        if "0.0.0.0/0" in code and "open_security_group_all" in deny_list:
            issues.append("Security group allows 0.0.0.0/0")
            compliant = False
        if 'acl = "public-read"' in code and "public_s3_acl" in deny_list:
            issues.append("S3 bucket has public ACL")
            compliant = False

        if not ch.get("version") and module in default_versions:
            ch["version"] = default_versions[module]

        missing_tags = [tag for tag in required_tags if tag not in code]
        if missing_tags:
            issues.append(f"Missing required tags: {missing_tags}")
            ch["needs_tag_fix"] = True

        region_match = re.findall(r"availability_zone\s*=\s*\"([a-z0-9-]+)\"", code)
        if region_match:
            region = region_match[0][:-1] if region_match[0][-1].isalpha() else region_match[0]
            if region not in allowed_regions:
                issues.append(f"Region {region} not allowed")
                compliant = False

        ch["policy_status"] = "compliant" if compliant else "non-compliant"
        if issues:
            ch["policy_issues"] = issues

        filtered_chunks.append(ch)

    return filtered_chunks


def save_tf_files_and_upload(request_id: str, llm_text: str):
    """Parse LLM output into individual Terraform files and upload to S3"""
    tmp_dir = f"/tmp/{request_id}"
    os.makedirs(tmp_dir, exist_ok=True)

    tf_files = {}
    matches = re.findall(r'--- (.*?) ---\n(.*?)(?=(\n--- |\Z))', llm_text, re.S)
    for fname, code, _ in matches:
        tf_files[fname.strip()] = code.strip()

    for fname, code in tf_files.items():
        local_path = os.path.join(tmp_dir, fname)
        with open(local_path, "w") as f:
            f.write(code)
        s3_key = f"requests/{request_id}/{fname}"
        s3.upload_file(local_path, ARTIFACTS_BUCKET, s3_key)

    shutil.rmtree(tmp_dir)
    return list(tf_files.keys())


def handler(event, context):
    """
    Lambda entry point
    Expects JSON input:
    {
        "ask": "<terraform request description>",
        "constraints": {}
    }
    """
    ask = event.get("ask", "Create a VPC with public and private subnets and an EC2 instance")
    constraints = event.get("constraints", {})
    request_id = str(uuid.uuid4())

    # 1. Call retriever
    retriever_output = call_retriever(ask, constraints)

    # 2. Load Org Policy
    org_policy = load_org_policy()

    # 3. Pull out chunks
    body = retriever_output.get("body", {})
    top_chunks = body.get("top_k_chunks", [])

    # 4. Determine requested modules
    requested_modules = determine_requested_modules(ask, org_policy.get("allowed_modules", []))

    # 5. Filter chunks
    filtered_chunks = filter_chunks_by_module_path(top_chunks, requested_modules)

    # 6. Apply policy enforcement
    enforced = policy_enforcer(filtered_chunks, org_policy)

    # 7. Build Bedrock prompt
    prompt = f"""
Human: You are a Terraform expert. 
Based on the following modules and org policy, generate the Terraform files: main.tf, variables.tf, outputs.tf.

Approved Modules:
{json.dumps(enforced, indent=2)}

Org Policy:
{json.dumps(org_policy, indent=2)}

Requirement:
{ask}

Output ONLY the Terraform code. Do NOT include any explanations, instructions, or notes. 
Return each file in this format:

--- main.tf ---
<terraform code>

--- variables.tf ---
<terraform code>

--- outputs.tf ---
<terraform code>

Assistant:
"""

    body = json.dumps({
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": prompt}]}
        ],
        "system": "You are a Terraform expert.",
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 3000
    })

    response = bedrock.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=body,
        contentType="application/json"
    )

    llm_output = json.loads(response['body'].read())
    llm_text = llm_output['content'][0]['text']

    # 8. Save files and upload
    tf_file_list = save_tf_files_and_upload(request_id, llm_text)

    return {
        "request_id": request_id,
        "files": tf_file_list,
        "retrieved_modules": [c.get("module_name") for c in enforced]
    }

