import json, urllib.request

run_id = "33262996251"
# 获取 jobs
url = f"https://api.github.com/repos/dmjorb/Seal/actions/runs/{run_id}/jobs"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req) as resp:
    data = json.loads(resp.read())

job_id = data["jobs"][0]["id"]
print(f"Job ID: {job_id}")

# 获取日志
log_url = f"https://api.github.com/repos/dmjorb/Seal/actions/jobs/{job_id}/logs"
req2 = urllib.request.Request(log_url, headers={"Accept": "application/vnd.github+json"})
try:
    with urllib.request.urlopen(req2) as resp:
        logs = resp.read().decode("utf-8")
        # 只打印最后 3000 字符（错误通常在最后）
        print(logs[-5000:])
except Exception as e:
    print(f"Error fetching logs: {e}")
