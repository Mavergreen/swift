#!/bin/sh
# platform: host-agnostic
#   usage: sh scripts/pins-bot.sh moved <base-ref>
#          sh scripts/pins-bot.sh values
#          sh scripts/pins-bot.sh apply <KEY=SHA256>...
#          sh scripts/pins-bot.sh fill <base-ref>
#          What .github/workflows/pins-bot.yml decides and writes when it fills a Swift bump's tarball pins on
#          Renovate's branch (scripts/pin-source-tarballs.sh computes and checks the hashes themselves).
#          moved   exit 0, printing them, when pins.env's source pin lines (LLVM_SHA, SWIFT_SHA, CMARK_SHA,
#                  *_TARBALL_SHA256) differ from those of the commit where this branch left <base-ref>; else 1;
#                  2 when git cannot tell (no merge base, a failed diff), never 1.
#          values  prints the three tarball pins as KEY=SHA256, one line, three words; refuses one that is not
#                  64 hex digits.
#          apply   writes those three pins into pins.env and nothing else; refuses another key, a value that is
#                  not 64 hex digits, or a key given twice, before writing anything; prints "changed" or
#                  "unchanged".
#          fill    the pins job's whole decision: exit 0 printing nothing when no source pin moved (moved) or
#                  scripts/pin-source-tarballs.sh --check exits 0 (current); when it exits 3 (stale), runs the
#                  write and prints the values. Any other --check status (1 is an error, never "stale"), a
#                  failed write, or a failed moved, exits 1 having printed nothing; only a status-3 --check
#                  ever leads to the write. Progress goes to stderr: stdout is the values or nothing.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$HERE/pins.env"
KEYS="LLVM_TARBALL_SHA256 SWIFT_TARBALL_SHA256 CMARK_TARBALL_SHA256"
hex64() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ "${#1}" -eq 64 ]; }
case "${1:-}" in
  moved)
    [ $# -eq 2 ] || { echo "usage: pins-bot.sh moved <base-ref>" >&2; exit 2; }
    base="$(git -C "$HERE" merge-base "$2" HEAD)" || { echo "pins-bot: no merge base with $2" >&2; exit 2; }
    # The diff is taken whole first: a git that fails must not read as "no source pin moved".
    d="$(git -C "$HERE" diff "$base" HEAD -- pins.env)" || { echo "pins-bot: git diff $base HEAD -- pins.env failed" >&2; exit 2; }
    lines="$(printf '%s\n' "$d" | grep -E '^[-+](LLVM_SHA|SWIFT_SHA|CMARK_SHA|[A-Z]+_TARBALL_SHA256)=' || :)"
    [ -n "$lines" ] || exit 1
    printf '%s\n' "$lines" ;;
  values)
    [ $# -eq 1 ] || { echo "usage: pins-bot.sh values" >&2; exit 2; }
    out=""
    for k in $KEYS; do
      v="$(sed -n "s/^$k=\"\\([^\"]*\\)\".*/\\1/p" "$PINS")"
      hex64 "$v" || { echo "pins-bot: pins.env's $k is '$v', not a SHA-256" >&2; exit 1; }
      out="$out${out:+ }$k=$v"
    done
    echo "$out" ;;
  apply)
    shift; [ $# -gt 0 ] || { echo "usage: pins-bot.sh apply <KEY=SHA256>..." >&2; exit 2; }
    seen=" "
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      case " $KEYS " in *" $k "*) ;; *) echo "pins-bot: '$k' is not a tarball pin ($KEYS)" >&2; exit 1 ;; esac
      case "$seen" in *" $k "*) echo "pins-bot: $k given twice" >&2; exit 1 ;; esac
      hex64 "$v" || { echo "pins-bot: $k's value '$v' is not a SHA-256" >&2; exit 1; }
      grep -q "^$k=\"" "$PINS" || { echo "pins-bot: pins.env has no $k line" >&2; exit 1; }
      seen="$seen$k "
    done
    tmp="$(mktemp "${TMPDIR:-/tmp}/pins-bot.XXXXXX")"
    awk -v kvs="$*" 'BEGIN { n = split(kvs, a, " "); for (i = 1; i <= n; i++) { j = index(a[i], "="); v[substr(a[i], 1, j - 1)] = substr(a[i], j + 1) } }
      { j = index($0, "=\""); k = (j > 1) ? substr($0, 1, j - 1) : ""
        if (k in v) { rest = substr($0, j + 2); q = index(rest, "\""); $0 = k "=\"" v[k] "\"" substr(rest, q + 1) }
        print }' "$PINS" > "$tmp"
    if cmp -s "$tmp" "$PINS"; then rm -f "$tmp"; echo unchanged; else cat "$tmp" > "$PINS"; rm -f "$tmp"; echo changed; fi ;;
  fill)
    [ $# -eq 2 ] || { echo "usage: pins-bot.sh fill <base-ref>" >&2; exit 2; }
    rc=0; sh "$HERE/scripts/pins-bot.sh" moved "$2" >&2 || rc=$?
    case "$rc" in
      0) ;;
      1) echo "pins-bot: no source pin moved: nothing to do" >&2; exit 0 ;;
      *) echo "pins-bot: could not tell whether a source pin moved (moved exited $rc)" >&2; exit 1 ;;
    esac
    rc=0; sh "$HERE/scripts/pin-source-tarballs.sh" --check >&2 || rc=$?
    case "$rc" in
      0) echo "pins-bot: the tarball pins are current: nothing to do" >&2; exit 0 ;;
      3) echo "pins-bot: a tarball pin is stale: writing them" >&2 ;;
      *) echo "pins-bot: pin-source-tarballs.sh --check exited $rc, an error rather than a stale pin: writing nothing" >&2; exit 1 ;;
    esac
    sh "$HERE/scripts/pin-source-tarballs.sh" >&2 || { echo "pins-bot: pin-source-tarballs.sh could not write the pins" >&2; exit 1; }
    sh "$HERE/scripts/pins-bot.sh" values ;;
  *) echo "usage: pins-bot.sh moved <base-ref> | values | apply <KEY=SHA256>... | fill <base-ref>" >&2; exit 2 ;;
esac
