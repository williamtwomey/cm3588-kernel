#!/usr/bin/env python3
"""Resolve git conflict hunks in a file, in order, by choice.

usage: resolve-hunks.py FILE CHOICE [CHOICE ...]
  ours | theirs | both (ours then theirs) | both-r (theirs then ours)
  both-sep (ours + "}\\n\\n" + theirs, for two new functions sharing a closing brace)
  @path  replace the hunk with that file's contents
The number of choices must match the number of hunks.
"""
import re
import sys

path, choices = sys.argv[1], sys.argv[2:]
src = open(path).read()
pat = re.compile(r"^<<<<<<< [^\n]*\n(.*?)^(?:\|\|\|\|\|\|\| [^\n]*\n.*?)?^=======\n(.*?)^>>>>>>> [^\n]*\n", re.S | re.M)
hunks = list(pat.finditer(src))
if len(hunks) != len(choices):
    sys.exit(f"{path}: {len(hunks)} hunks, {len(choices)} choices")
out, pos = [], 0
for m, c in zip(hunks, choices):
    ours, theirs = m.group(1), m.group(2)
    out.append(src[pos:m.start()])
    if c == "ours":
        out.append(ours)
    elif c == "theirs":
        out.append(theirs)
    elif c == "both":
        out.append(ours + theirs)
    elif c == "both-r":
        out.append(theirs + ours)
    elif c == "both-sep":
        out.append(ours + "}\n\n" + theirs)
    elif c.startswith("@"):
        out.append(open(c[1:]).read())
    else:
        sys.exit(f"bad choice {c}")
    pos = m.end()
out.append(src[pos:])
open(path, "w").write("".join(out))
print(f"{path}: resolved {len(hunks)}")
