import json, urllib.request

run_id = "33262996251"
url = f"https://api.github.com/repos/dmjorb/Seal/actions/runs/{run_id}/jobs"
req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
with urllib.request.urlopen(req) as resp:
    data = json.loads(resp.read())

for job in data["jobs"]:
    print(f"Job: {job['name']} | Status: {job['status']} | Conclusion: {job['conclusion']}")
    for step in job["steps"]:
        print(f"  Step: {step['name']} | Status: {step['status']} | Conclusion: {step['conclusion']}")
