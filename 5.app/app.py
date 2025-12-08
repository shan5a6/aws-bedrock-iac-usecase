from flask import Flask, request, render_template, Response, redirect, url_for, session
import boto3, json, os, time, random
from functools import wraps
from botocore.exceptions import ClientError
import git
from git import Repo
import subprocess
import shutil

# ---------- Configuration ----------
REGION = os.environ.get("AWS_REGION", "us-east-1")
COMPOSER_FUNCTION = os.environ.get("COMPOSER_LAMBDA", "iac-rag2-prod-compose-v2")
USE_BASIC_AUTH = os.environ.get("USE_BASIC_AUTH", "true").lower() == "true"
SECRETS_MANAGER_ARN = os.environ.get("COMPOSER_CRED_SECRET", "terraform-composer-credential")

# ---------- AWS Clients ----------
lambda_client = boto3.client("lambda", region_name=REGION)
secrets_client = boto3.client("secretsmanager", region_name=REGION)
s3_client = boto3.client("s3")

app = Flask(__name__)
app.secret_key = os.urandom(24)

# ---------- Optional Basic Auth ----------
def get_basic_auth_credentials(secret_name):
    """Try to fetch username/password from Secrets Manager. Returns (username, password) or (None, None)."""
    try:
        resp = secrets_client.get_secret_value(SecretId=secret_name)
        secret = json.loads(resp["SecretString"])
        return secret.get("username"), secret.get("password")
    except Exception as e:
        app.logger.warning("Could not fetch secret %s: %s", secret_name, str(e))
        return None, None

USERNAME, PASSWORD = (None, None)
if USE_BASIC_AUTH:
    USERNAME, PASSWORD = get_basic_auth_credentials(SECRETS_MANAGER_ARN)

def check_auth(username, password):
    if not (USERNAME and PASSWORD):
        return False
    return username == USERNAME and password == PASSWORD

def authenticate():
    return Response(
        'Could not verify your access level.\n'
        'You have to login with proper credentials', 401,
        {'WWW-Authenticate': 'Basic realm="Login Required"'}
    )

def requires_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not USE_BASIC_AUTH:
            return f(*args, **kwargs)
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return authenticate()
        return f(*args, **kwargs)
    return decorated

# ---------- Composer Lambda Caller (resilient) ----------
def call_composer(prompt):
    payload = {"ask": prompt}
    try:
        response = lambda_client.invoke(
            FunctionName=COMPOSER_FUNCTION,
            Payload=json.dumps(payload),
            InvocationType="RequestResponse",
        )
        resp_payload = json.loads(response["Payload"].read())
        if "errorMessage" in resp_payload:
            return {"error": resp_payload["errorMessage"]}
        
        resp_payload.setdefault("validation", {})
        resp_payload.setdefault("retrieved_modules", [])
        resp_payload.setdefault("files", [])
        
        return resp_payload

    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code")
        if error_code == "ThrottlingException":
            return {"error": "Too many requests. Please try again in a moment."}
        else:
            return {"error": f"AWS client error: {str(e)}"}
    except Exception as e:
        return {"error": f"Composer function error: {str(e)}"}

# ---------- S3 and Git Configuration ----------
S3_BUCKET = os.environ.get("S3_BUCKET", "iac-rag2-prod-artifacts")
REPO_CLONE_DIR = "/tmp/repo"

# ---------- Git Operations Function (Enhanced) ----------
def download_and_commit(request_id, git_url, git_username, git_token):
    s3 = boto3.client("s3")
    
    # Clean up previous repo clone
    if os.path.exists(REPO_CLONE_DIR):
        shutil.rmtree(REPO_CLONE_DIR)

    # 1. Construct the authenticated Git URL
    authenticated_url = git_url
    if git_username and git_token:
        if "https://" in git_url:
            parts = git_url.split("https://")
            authenticated_url = f"https://{git_username}:{git_token}@{parts[1]}"
        elif "http://" in git_url:
            parts = git_url.split("http://")
            authenticated_url = f"http://{git_username}:{git_token}@{parts[1]}"
    
    # 2. Clone the repository
    try:
        Repo.clone_from(authenticated_url, REPO_CLONE_DIR)
        app.logger.info(f"Successfully cloned repository from {authenticated_url}")
    except git.exc.GitCommandError as e:
        app.logger.error(f"Failed to clone repository: {e}")
        return f"Failed to clone repository. Please check your URL, username, and token. Error: {str(e)}"
    except Exception as e:
        app.logger.error(f"An unexpected error occurred during cloning: {e}")
        return f"An unexpected error occurred during cloning: {str(e)}"

    # 3. Download files from S3 directly to the repo root
    try:
        s3_prefix = f"requests/{request_id}/"
        response = s3.list_objects_v2(Bucket=S3_BUCKET, Prefix=s3_prefix)
        
        files_downloaded = []
        if "Contents" in response:
            for obj in response["Contents"]:
                key = obj["Key"]
                file_name = os.path.basename(key)
                download_path = os.path.join(REPO_CLONE_DIR, file_name)
                s3.download_file(S3_BUCKET, key, download_path)
                files_downloaded.append(file_name)
        else:
            return "No files found for this request ID."
            
    except ClientError as e:
        app.logger.error(f"S3 download failed: {e}")
        return f"Error downloading files from S3: {str(e)}"
    except Exception as e:
        app.logger.error(f"An unexpected error occurred during download: {e}")
        return f"An unexpected error occurred during download: {str(e)}"
        
    # 4. Git Operations
    try:
        repo = Repo(REPO_CLONE_DIR)
        
        # Checkout the master branch
        repo.git.checkout("master")
        
        new_branch = f"feat/terraform-composer-{request_id}"
        
        # Create a new branch from the master branch
        repo.git.checkout("-b", new_branch)
        
        # Add files to the staging area and commit
        repo.index.add(files_downloaded)
        repo.index.commit(f"feat: Add Terraform files for request {request_id}")
        
        # Push the changes
        origin = repo.remote(name="origin")
        origin.push(refspec=f"{new_branch}:{new_branch}")
        
    except git.exc.GitCommandError as e:
        app.logger.error(f"Git command failed: {e}")
        return f"Git command failed: {str(e)}"
    except Exception as e:
        app.logger.error(f"An unexpected Git error occurred: {e}")
        return f"An unexpected Git error occurred: {str(e)}"
        
    # 5. Raise a Pull Request using GitHub CLI (gh)
    try:
        pr_title = f"feat: Terraform files for request {request_id}"
        pr_body = f"This PR was automatically generated by Terraform Composer.\n\nFiles generated for request ID: `{request_id}`:\n\n"
        for f in files_downloaded:
            pr_body += f"- {f}\n"

        env_vars = os.environ.copy()
        env_vars['GH_TOKEN'] = git_token

        cmd = ["gh", "pr", "create", "--title", pr_title, "--body", pr_body, "--base", "master", "--head", new_branch]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, cwd=REPO_CLONE_DIR, env=env_vars)
        pr_url = result.stdout.strip()
        
        return f"Successfully created PR: <a href='{pr_url}'>{pr_url}</a>"
        
    except FileNotFoundError:
        return "GitHub CLI (`gh`) not found. Please install and authenticate it to create PRs."
    except subprocess.CalledProcessError as e:
        app.logger.error(f"GitHub CLI command failed: {e.stderr}")
        return f"GitHub CLI command failed: {e.stderr}"
    except Exception as e:
        app.logger.error(f"An unexpected PR creation error occurred: {e}")
        return f"An unexpected PR creation error occurred: {str(e)}"

# ---------- Routes (Updated) ----------
@app.route("/", methods=["GET", "POST"])
@requires_auth
def home():
    error = None
    result = None
    pr_result = None
    prompt = ""
    git_url = ""
    git_username = ""
    git_token = ""

    if request.method == "POST":
        prompt = request.form.get("prompt")
        git_url = request.form.get("git_url")
        git_username = request.form.get("git_username")
        git_token = request.form.get("git_token")
        
        if not prompt:
            error = "Please enter a prompt."
        elif not git_url:
            error = "Please enter a Git repository URL."
        else:
            result = call_composer(prompt)
            session["result"] = result
            session["git_url"] = git_url
            session["git_username"] = git_username
            session["git_token"] = git_token

            if "request_id" in result:
                pr_result = download_and_commit(result["request_id"], git_url, git_username, git_token)
                session["pr_result"] = pr_result
            return redirect(url_for("home"))

    if "result" in session:
        result = session.pop("result")
    if "pr_result" in session:
        pr_result = session.pop("pr_result")
    if "git_url" in session:
        git_url = session.pop("git_url")
    if "git_username" in session:
        git_username = session.pop("git_username")
    if "git_token" in session:
        git_token = session.pop("git_token")

    return render_template("index.html", result=result, prompt=prompt, git_url=git_url, git_username=git_username, git_token=git_token, pr_result=pr_result, error=error)

# ---------- Run (No changes needed) ----------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=True)
