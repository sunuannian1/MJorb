import json
with open(r"C:\Users\DMJ\Desktop\Seal--source-e50b594\runs.json", encoding="utf-8") as f:
    d = json.load(f)
for r in d.get("workflow_runs", []):
    print(f"{r['id']} | {r['name']} | {r['status']} | {r['conclusion']} | {r['head_branch']} | {r['created_at']}")
