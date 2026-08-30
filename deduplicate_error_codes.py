import os
import re
from collections import defaultdict

root = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal"
pattern = re.compile(r'(code:\s*")(SEAL-[A-Z]+-\d+)(")')

# 第一步：收集所有错误码出现位置（按文件+行号排序）
all_occurrences = []
for dirpath, _, filenames in os.walk(root):
    for fname in filenames:
        if not fname.endswith('.swift'):
            continue
        fpath = os.path.join(dirpath, fname)
        with open(fpath, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        for lineno, line in enumerate(lines, 1):
            for m in pattern.finditer(line):
                code = m.group(2)
                all_occurrences.append((fpath, lineno, code, m.start(), m.end()))

# 按文件路径+行号排序
all_occurrences.sort(key=lambda x: (x[0], x[1]))

# 第二步：为每个重复的错误码分配唯一后缀
# 策略：每个错误码的第一次出现保持原样，后续出现加 a, b, c...
code_count = defaultdict(int)
replacements = []  # (fpath, lineno, old_code, new_code, start, end)
for fpath, lineno, code, start, end in all_occurrences:
    idx = code_count[code]
    if idx == 0:
        new_code = code
    else:
        suffix = chr(ord('a') + idx - 1)
        new_code = f"{code}{suffix}"
    code_count[code] += 1
    replacements.append((fpath, lineno, code, new_code, start, end))

# 统计重复的
duplicates = {code: count for code, count in code_count.items() if count > 1}
print(f"Found {len(duplicates)} duplicate error codes, {sum(duplicates.values())} occurrences")

# 第三步：按文件分组替换
by_file = defaultdict(list)
for fpath, lineno, old_code, new_code, start, end in replacements:
    if old_code != new_code:
        by_file[fpath].append((lineno, old_code, new_code))

modified_files = 0
for fpath, reps in by_file.items():
    with open(fpath, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    for lineno, old_code, new_code in reps:
        line = lines[lineno - 1]
        lines[lineno - 1] = line.replace(f'"{old_code}"', f'"{new_code}"', 1)
    
    with open(fpath, 'w', encoding='utf-8') as f:
        f.writelines(lines)
    modified_files += 1
    print(f"Modified: {os.path.basename(fpath)} ({len(reps)} changes)")

print(f"\nTotal modified files: {modified_files}")
print("Done!")
