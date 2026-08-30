import json, urllib.request

url = "https://api.github.com/repos/dmjorb/Seal/actions/runs?per_page=5"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req) as resp:
    data = json.loads(resp.read())

for r in data["workflow_runs"]:
    print(f"{r['id']} | {r['status']} | {r['conclusion']} | {r['name']} | {r['head_sha'][:7]}")
