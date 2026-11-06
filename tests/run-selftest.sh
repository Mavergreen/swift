#!/bin/sh
# platform: macOS-only -- runs the installed runtime's Mach-O tests, and Guard Malloc is libgmalloc.dylib
#   usage: run-selftest.sh [--gate|--loads]
#          Validates the Swift runtime INSTALLED on this Mac (OS X 10.9) by running every bin/* test,
#          which were built with an rpath of $SWIFT_RUNTIME_PREFIX/lib/swift (make-selftest.sh).
#            (default)  each test once
#            --gate     the acceptance bar: SELFTEST_RUNS consecutive clean exits (default 500),
#                       then 10 runs under Guard Malloc + MallocScribble + MallocGuardEdges; then
#                       each of upstream's own tests (upstream/bin/*, when make-selftest.sh's
#                       SELFTEST_SUPPORT built them) SELFTEST_UPSTREAM_RUNS times (default 20),
#                       then once under Guard Malloc
#            --loads    each test once with DYLD_PRINT_LIBRARIES=1: libswiftCore must load, and
#                       every libswift*.dylib that the runtime ships (the names in
#                       $SWIFT_RUNTIME_PREFIX/lib/swift) must load from there, every other libswift*
#                       (test support) from this bundle's lib/. The one mode that sets a DYLD
#                       variable, and only on the test's own command.
#          The default and --loads run upstream/bin/* too, once each, after bin/*.
#          Every run is killed after SELFTEST_TIMEOUT seconds (default 60) and reported as a timeout:
#          a hang must fail the gate, not stall it. That needs perl (10.9 has /usr/bin/perl); without
#          one this refuses to run, rather than run without a timeout.
#          SWIFT_RUNTIME_PREFIX  default /usr/local/mavergreen/swift-runtime; must match the rpath the
#                                tests were built with
#          SELFTEST_GMALLOC      default /usr/lib/libgmalloc.dylib
#          SELFTEST_TIMEOUT      seconds per run, default 60
#          SELFTEST_UPSTREAM_RUNS  --gate's runs of each upstream/bin/* test, default 20
#          SELFTEST_PERL         the perl to time runs with; default /usr/bin/perl, else perl on PATH
#          Exit 0 all pass, 1 any failure or any DYLD_* variable set, 2 any other argument, 77 no
#          runtime installed (the family SKIP code: a CI runner never has one) or no bin/ here (the
#          repo's own tests/, which is not a bundle).
set -eu
cd "$(dirname "$0")"
# Anything else once ran quick mode: a mistyped -gate printed ALL PASS as if it had gated.
case "$#:${1:-}" in
  0:|1:--gate|1:--loads) ;;
  *) echo "usage: run-selftest.sh [--gate|--loads]" >&2; exit 2 ;;
esac

PREFIX="${SWIFT_RUNTIME_PREFIX:-/usr/local/mavergreen/swift-runtime}"
CORE="$PREFIX/lib/swift/libswiftCore.dylib"
GMALLOC="${SELFTEST_GMALLOC:-/usr/lib/libgmalloc.dylib}"
RUNS="${SELFTEST_RUNS:-500}"
UPRUNS="${SELFTEST_UPSTREAM_RUNS:-20}"
TIMEOUT="${SELFTEST_TIMEOUT:-60}"
GMALLOC_RUNS=10

[ -f "$CORE" ] || {
  echo "Swift runtime not found at $CORE" >&2
  echo "Install it first:  sudo installer -pkg swift-runtime-*.pkg -target /" >&2
  exit 77
}
# run-repo-tests.sh runs every tests/*.sh, this one included, from the repo's tests/, which is not a
# bundle; wherever a runtime is installed, "No tests in bin/" below failed the whole suite. A bin/
# that exists but is empty is a broken bundle, and still fails.
[ -d bin ] || { echo "not a self-test bundle (no bin/) -- skipping" >&2; exit 77; }
# The gate's rule is "no DYLD variables": DYLD_LIBRARY_PATH and its kin outrank the rpath, so the
# tests could validate some other runtime. (Guard Malloc's DYLD_INSERT_LIBRARIES below is set on
# each command, never inherited.)
dyld="$(env | sed -n 's/^\(DYLD_[A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' ')"
[ -z "$dyld" ] || { echo "refusing to run with DYLD_* set: ${dyld% }" >&2; exit 1; }
case "$RUNS" in
  ''|*[!0-9]*|0) echo "SELFTEST_RUNS must be a positive integer (got '$RUNS')" >&2; exit 1 ;;
esac
case "$UPRUNS" in
  ''|*[!0-9]*|0) echo "SELFTEST_UPSTREAM_RUNS must be a positive integer (got '$UPRUNS')" >&2; exit 1 ;;
esac

case "$TIMEOUT" in
  ''|*[!0-9]*|0) echo "SELFTEST_TIMEOUT must be a positive integer (got '$TIMEOUT')" >&2; exit 1 ;;
esac
if [ -n "${SELFTEST_PERL:-}" ]; then PERL="$SELFTEST_PERL"
elif [ -x /usr/bin/perl ]; then PERL=/usr/bin/perl
else PERL="$(command -v perl || :)"; fi
[ -n "$PERL" ] && [ -x "$PERL" ] || { echo "no perl (${SELFTEST_PERL:-/usr/bin/perl}): cannot time-limit the runs, so not running them" >&2; exit 1; }

# limited ARGS... : runs ARGS under the timeout; exit 142 (SIGALRM) means it ran out, a signal N 128+N
# as sh reports it. Leading NAME=value words (DYLD_* only) go into the child's environment from inside
# perl: a modern macOS's SIP strips them from a platform perl's own environment, so `VAR=x perl ...`
# would never reach the test; on 10.9 it makes no difference. The test runs in a process group of its
# own, and a timeout kills the whole group: StdlibUnittest runs each test case in a child process, which
# a kill of the test alone would leave spinning, orphaned, through the rest of the gate.
limited() {
  "$PERL" -e '
    my $t = shift; while ($ARGV[0] =~ /^(DYLD_\w+)=(.*)$/s) { $ENV{$1} = $2; shift }
    my $pid = fork; defined $pid or exit 127;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
    setpgrp($pid, $pid);   # (both sides, so the group exists whichever runs first)
    local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid $pid, 0; exit 142 };
    alarm $t; waitpid $pid, 0; alarm 0;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$TIMEOUT" "$@"
}
# reason LABEL RC : the failure text for run LABEL that exited RC
reason() { if [ "$2" = 142 ]; then echo "$1 timed out after $TIMEOUT s"; else echo "$1 exited non-zero"; fi; }

MODE="${1:-quick}"
pass=0; fail=0; failed=""
if [ "$MODE" = "--loads" ]; then
  # What the runtime pkg ships is read off the prefix itself, so a later layer needs no edit here.
  # dyld prints the path as it opened it (maybe through a symlink, maybe bin/../lib), so compare physical dirs.
  RTDIR="$PREFIX/lib/swift"; RTDIR_P="$(cd -P "$RTDIR" && pwd)"; SUPDIR="$(pwd -P)/lib"
  shipped="$(cd "$RTDIR" && ls -1 libswift*.dylib 2>/dev/null || :)"
fi
# run_one <test> <runs> <Guard Malloc runs> : runs one test as MODE says; counts and names it
run_one() {
  t="$1"; runs="$2"; gmruns="$3"; ok=1; why=""
  if [ "$MODE" = "--loads" ]; then
    # DYLD_PRINT_LIBRARIES goes to stderr (10.9's dyld; modern ones too).
    rc=0; err="$(limited DYLD_PRINT_LIBRARIES=1 "./$t" 2>&1 >/dev/null)" || rc=$?
    [ "$rc" = 0 ] || { ok=0; why="$(reason "run 1 of 1" "$rc") with DYLD_PRINT_LIBRARIES=1"; }
    core=0
    for p in $(printf '%s\n' "$err" | sed -n 's/^[^/]*\(\/[^ ]*libswift[^ ]*\.dylib\).*$/\1/p' | sort -u); do
      [ "$ok" = 1 ] || break
      lib="$(basename "$p")"; dir="$(dirname "$p")"
      # (physical, so bin/../lib and a symlinked prefix compare as the places they are)
      dir="$(cd -P "$dir" 2>/dev/null && pwd || echo "$dir")"
      if printf '%s\n' "$shipped" | grep -qx -- "$lib"; then
        [ "$dir" = "$RTDIR_P" ] || { ok=0; why="$lib loaded from $p, not from $RTDIR"; }
        [ "$lib" != libswiftCore.dylib ] || core=1
      else
        [ "$dir" = "$SUPDIR" ] || { ok=0; why="$lib loaded from $p, not from the bundle's $SUPDIR"; }
      fi
    done
    # A test that printed no libswiftCore load (no DYLD output read, say) proved nothing about where it loads from.
    [ "$ok" = 0 ] || [ "$core" = 1 ] || { ok=0; why="no libswiftCore.dylib loaded from $RTDIR (DYLD_PRINT_LIBRARIES showed none)"; }
    label="loads"
  elif [ "$MODE" = "--gate" ]; then
    n=0
    while [ "$n" -lt "$runs" ]; do
      rc=0; limited "./$t" >/dev/null 2>&1 || rc=$?
      [ "$rc" = 0 ] || { ok=0; why="$(reason "run $((n + 1)) of $runs" "$rc")"; break; }
      n=$((n + 1))
    done
    g=0
    while [ "$ok" = 1 ] && [ "$g" -lt "$gmruns" ]; do
      # libgmalloc announces itself on stderr ("GuardMalloc[pid]: ...") on 10.9 and on modern macOS
      # alike; its absence means the run was not guarded, which must not read as a pass.
      rc=0; err="$(MallocScribble=1 MallocGuardEdges=1 limited DYLD_INSERT_LIBRARIES="$GMALLOC" "./$t" 2>&1 >/dev/null)" || rc=$?
      [ "$rc" = 0 ] || { ok=0; why="$(reason "Guard Malloc run $((g + 1)) of $gmruns" "$rc")"; break; }
      case "$err" in
        *'GuardMalloc['*) ;;
        *) ok=0; why="Guard Malloc did not load ($GMALLOC)"; break ;;
      esac
      g=$((g + 1))
    done
    label="${runs}x + ${gmruns}x Guard Malloc"
  else
    rc=0; limited "./$t" >/dev/null 2>&1 || rc=$?
    [ "$rc" = 0 ] || { ok=0; why="$(reason "run 1 of 1" "$rc")"; }
    label="run"
  fi
  if [ "$ok" = 1 ]; then
    printf '  PASS (%s): %s\n' "$label" "$name"; pass=$((pass + 1))
  else
    printf '  FAIL: %s -- %s\n' "$name" "$why"; fail=$((fail + 1)); failed="$failed $name"
  fi
}
for t in bin/*; do
  [ -f "$t" ] && [ -x "$t" ] || continue
  name="$(basename "$t")"
  run_one "$t" "$RUNS" "$GMALLOC_RUNS"
done
# Upstream's own tests (make-selftest.sh's SELFTEST_SUPPORT), after this repo's: fewer runs each, as
# there are many more of them and each runs a whole suite (INGREDIENTS.md's gate paragraph sizes it).
for t in upstream/bin/*; do
  [ -f "$t" ] && [ -x "$t" ] || continue
  name="$t"
  run_one "$t" "$UPRUNS" 1
done

echo "----------------------------------------"
echo "passed=$pass  failed=$fail"
[ $((pass + fail)) -gt 0 ] || { echo "No tests in bin/ -- nothing was validated." >&2; exit 1; }
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS -- the Swift runtime works on this machine."
else
  echo "FAILURES:$failed"
  echo "(Please report it with your exact OS X build: sw_vers.)"
  exit 1
fi
