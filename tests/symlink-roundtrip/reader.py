import os
import sys

src, dst = sys.argv[1], sys.argv[2]
lines = []
for dirpath, dirnames, filenames in os.walk(src):
    dirnames.sort()
    for n in sorted(dirnames + filenames):
        full = os.path.join(dirpath, n)
        rel = "./" + os.path.relpath(full, src)
        lines.append(rel)
        if os.path.islink(full):
            lines.append(f"{rel} -> {os.readlink(full)}")
with open(dst, "w") as f:
    f.write("\n".join(lines) + "\n")
