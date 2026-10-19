#!/bin/sh
# platform: host-agnostic
# usage: sh tests/patches-context-test.sh
#   Every hunk of every patches/*/*.patch has 3 lines of context before its first change and 3 after its
#   last, unless its old-file range starts at line 1 (or 0, a new file), or it is its file's last hunk with
#   3 before and fewer after: one that ends at the end of the file, which GNU patch anchors there (shown on
#   10.9's 2.5.8 at -F 0 with runtime patch 0009). OS X 10.9's GNU patch 2.5.8, run
#   at -F 0 as patch_source does, refuses a hunk with uneven context that git apply and BSD patch accept,
#   so a hand-trimmed patch must fail here, on any host, not on 10.9 at the next Swift bump.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
bad="$(for p in "$REPO"/patches/*/*.patch; do
  awk -v f="${p#"$REPO"/}" '
    left > 0 || rem > 0 {                       # inside a hunk, which the header'"'"'s line counts delimit
      c = substr($0, 1, 1)
      if (c == "\\") next
      if (c == "+") { rem--; seen = 1; trail = 0 }
      else if (c == "-") { left--; seen = 1; trail = 0 }
      else { left--; rem--; if (seen) trail++; else lead++ }
      if (left <= 0 && rem <= 0 && start > 1 && (lead != 3 || trail != 3)) {
        msg = sprintf("%s: %s -- %d lines of leading and %d of trailing context, not 3 and 3\n", f, h, lead, trail)
        if (lead == 3 && trail < 3) pending = msg; else printf "%s", msg   # fine only as the file'"'"'s last hunk
      }
      next
    }
    /^(diff |--- )/ { pending = "" }            # a new file: the previous hunk was its file'"'"'s last
    /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ {
      if (pending != "") { printf "%s", pending; pending = "" }
      h = $0; split($2, o, ","); split($3, w, ","); start = substr(o[1], 2) + 0
      left = (o[2] == "" ? 1 : o[2]) + 0; rem = (w[2] == "" ? 1 : w[2]) + 0
      lead = 0; trail = 0; seen = 0
    }' "$p"
done)"
[ -z "$bad" ] || fail "$bad"
echo "PASS"
