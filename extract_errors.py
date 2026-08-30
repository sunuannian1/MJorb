import os, re, json

root = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal"
results = []

for dirpath, dirnames, filenames in os.walk(root):
    for fn in filenames:
        if not fn.endswith(".swift"):
            continue
        fp = os.path.join(dirpath, fn)
        with open(fp, encoding="utf-8") as f:
            content = f.read()
        # Find ImportFailure( blocks
        pattern = r'ImportFailure\(\s*title:\s*"([^"]*)",\s*reason:\s*"([^"]*)",\s*recovery:\s*"([^"]*)",\s*code:\s*"([^"]*)"'
        for m in re.finditer(pattern, content):
            results.append({
                "file": os.path.relpath(fp, root),
                "title": m.group(1),
                "reason": m.group(2),
                "recovery": m.group(3),
                "code": m.group(4),
            })
        # Also find Self.failure( blocks
        pattern2 = r'Self\.failure\(\s*title:\s*"([^"]*)",\s*reason:\s*"([^"]*)",\s*recovery:\s*"([^"]*)",\s*code:\s*"([^"]*)"'
        for m in re.finditer(pattern2, content):
            results.append({
                "file": os.path.relpath(fp, root),
                "title": m.group(1),
                "reason": m.group(2),
                "recovery": m.group(3),
                "code": m.group(4),
            })

# Deduplicate by code
seen = {}
for r in results:
    if r["code"] not in seen:
        seen[r["code"]] = r

for code, r in sorted(seen.items()):
    print(f"[{code}] {r['file']}")
    print(f"  title: {r['title']}")
    print(f"  reason: {r['reason']}")
    print(f"  recovery: {r['recovery']}")
    print()

print(f"Total unique errors: {len(seen)}")
