import os
import sys

out = sys.argv[1]
os.makedirs(out + "/sub")
with open(out + "/sub/real.txt", "w") as f:
    f.write("hi\n")
os.symlink("/nix/store/00000000000000000000000000000000-spike/bin/x",
           out + "/abs-link")
os.symlink("../outside/escaping", out + "/sub/escape-link")
os.symlink("sub/real.txt", out + "/internal-link")
