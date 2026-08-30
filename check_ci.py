import json, urllib.request
url = "https://api.github.com/repos/dmjorb/Seal/actions/runs?per_page=5"
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
with urllib.request.urlopen(req) as resp:
    d = json.loads(resp.read())
for r in d.get("workflow_runs", []):
    print(f"{r['id']} | {r['name']} | {r['status']} | {r.get('conclusion','')} | {r['head_branch']} | {r['created_at']}")
