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
#                       (test support) from this bundle's lib/ or the OS's own (/usr/lib, /System); and
#                       exactly one libc++.1.dylib other than the OS's may stay loaded, libcxx22's from
#                       $SWIFT_RUNTIME_PREFIX/../libcxx22/lib, where the runtime's rpath reaches it. The one
#                       mode that sets a DYLD variable, and only on the test's own command.
#          The default and --loads run upstream/bin/* too, once each, after bin/*.
#          An upstream/bin/<N> (or <N>-Onone) with an upstream/check/<N>.args passes only when each run's
#          stdout, its exit status checked first, matches upstream/check/<N>.swift under FileCheck with
#          the options that file lists, one per line (make-selftest.sh); without a FileCheck the test fails.
#          A mismatch prints the first 20 lines of FileCheck's diagnostics under its FAIL line.
#          Every run is killed after SELFTEST_TIMEOUT seconds (default 60; upstream/bin/*, SELFTEST_UPSTREAM_TIMEOUT)
#          and reported as a timeout:
#          a hang must fail the gate, not stall it. That needs perl (10.9 has /usr/bin/perl); without
#          one this refuses to run, rather than run without a timeout.
#          SWIFT_RUNTIME_PREFIX  default /usr/local/mavergreen/swift-runtime; must match the rpath the
#                                tests were built with
#          SELFTEST_GMALLOC      default /usr/lib/libgmalloc.dylib
#          SELFTEST_TIMEOUT      seconds per run, default 60
#          SELFTEST_UPSTREAM_RUNS  --gate's runs of each upstream/bin/* test, default 20
#          SELFTEST_UPSTREAM_TIMEOUT  seconds per run of an upstream/bin/* test, default 180: some of upstream's
#                                suites are long, clock's -Onone Guard Malloc run 45 s on ultimate-hat and
#                                cancellation_handler_concurrent's 65 s, and a slower VM must not time them
#                                out; a hang still fails, three minutes later (INGREDIENTS' gate paragraph)
#          SELFTEST_SAMPLE       the sample(1) to run on a test that times out, before it is killed, on each live
#                                process of its group; default /usr/bin/sample (in 10.9's base system). A few
#                                seconds each, about 30 at most. The whole text of each goes to
#                                $SELFTEST_SAMPLES/sample-<pid>.txt (default ./samples), its top-of-stack
#                                section (else the first 150 lines) to stderr. No sample, or one that fails: one
#                                line says so, and the run is killed and reported as before.
#          SELFTEST_PERL         the perl to time runs with; default /usr/bin/perl, else perl on PATH
#          SELFTEST_FILECHECK    the FileCheck for upstream/check/; default /usr/local/mavergreen/clang22/bin/FileCheck,
#                                timed like a run
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
UPTIMEOUT="${SELFTEST_UPSTREAM_TIMEOUT:-180}"
FC="${SELFTEST_FILECHECK:-/usr/local/mavergreen/clang22/bin/FileCheck}"
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
case "$UPTIMEOUT" in
  ''|*[!0-9]*|0) echo "SELFTEST_UPSTREAM_TIMEOUT must be a positive integer (got '$UPTIMEOUT')" >&2; exit 1 ;;
esac
if [ -n "${SELFTEST_PERL:-}" ]; then PERL="$SELFTEST_PERL"
elif [ -x /usr/bin/perl ]; then PERL=/usr/bin/perl
else PERL="$(command -v perl || :)"; fi
[ -n "$PERL" ] && [ -x "$PERL" ] || { echo "no perl (${SELFTEST_PERL:-/usr/bin/perl}): cannot time-limit the runs, so not running them" >&2; exit 1; }

# limited ARGS... : runs ARGS under the timeout; exit 142 (SIGALRM) means it ran out, a signal N 128+N
# as sh reports it. Leading NAME=value words (DYLD_* only) go into the child's environment from inside
# perl: a modern macOS's SIP strips them from a platform perl's own environment, so `VAR=x perl ...`
# would never reach the test; on 10.9 it makes no difference. The test runs in a process group of its
# own, and the end of the run, however it ends, kills the whole group: StdlibUnittest runs each test case in a
# child process, which a kill of the test alone, or a crash of it, would leave spinning, orphaned, through the
# rest of the gate.
limited() {
  "$PERL" -e '
    use File::Path qw(make_path);
    my $t = shift; my $sampling = shift; while ($ARGV[0] =~ /^(DYLD_\w+)=(.*)$/s) { $ENV{$1} = $2; shift }
    my $pid = fork; defined $pid or exit 127;
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV or exit 127 }
    setpgrp($pid, $pid);   # (both sides, so the group exists whichever runs first)
    # sample_group: where is every live process of the test group stuck? Whole samples go to files under
    # $SELFTEST_SAMPLES, an excerpt of each to stderr (CI keeps the job log, nothing else of ours); a
    # missing or failing sample is one line and changes nothing: the kill and the 142 follow as ever.
    my $E;   # (the log handle: closed by the handler after sample_group, with PIPE still ignored)
    sub sample_group {
      # fd 3 is the gate itself stderr: a run stderr is captured for its FAIL line, the excerpt must reach the job log
      open($E, ">&3") or $E = \*STDERR;
      select((select($E), $| = 1)[0]);   # (unbuffered: an excerpt must be out before the kill)
      my $sample = $ENV{SELFTEST_SAMPLE} || "/usr/bin/sample";
      my $dir = $ENV{SELFTEST_SAMPLES} || "samples";
      unless (-x $sample) { print $E "timed out; not sampling: $sample is not available\n"; return }
      my @pids; my $ps = `ps -A -o pid=,pgid= 2>/dev/null`;
      for my $l (split /\n/, $ps) { push @pids, $1 if $l =~ /^\s*(\d+)\s+(\d+)\s*$/ && $2 == $pid }
      unless (@pids) { print $E "timed out; not sampling: no live process in the group\n"; return }
      make_path($dir); my $each = int(24 / @pids); $each = 3 if $each > 3; $each = 1 if $each < 1;
      # platform: the test has already outrun its limit, so 142 is right whether or not a sample comes of this.
      # Freeze the group first, so the snapshots agree and nothing finishes in the window; sample(1) is
      # not known to attach to a stopped process, so an empty sample is reported as such.
      kill "STOP", -$pid;
      my $t0 = time;   # (30 s at the very most: each sample is killed when its share runs out, none starts after 24 s)
      for my $p (@pids) {
        last if time - $t0 > 24;
        my $f = "$dir/sample-$p.txt"; my $k = fork;
        unless (defined $k) { print $E "timed out; sampling pid $p failed: no fork\n"; next }
        if ($k == 0) { setpgrp(0, 0); open STDOUT, ">", $f or exit 127; open STDERR, ">&STDOUT"; exec {$sample} $sample, $p, $each or exit 127 }
        setpgrp($k, $k);
        my $limit = $each + 2; $limit = 30 - (time - $t0) if $limit > 30 - (time - $t0);
        my ($end, $got) = (time + $limit, 0);
        until ($got = waitpid($k, 1)) { last if time >= $end; select(undef, undef, undef, 0.1) }   # 1 is WNOHANG
        unless ($got) { kill "KILL", -$k; kill "KILL", $k; waitpid $k, 0; print $E "timed out; $sample $p did not finish in $limit s, killed\n"; next }
        if ($? != 0) { print $E "timed out; $sample $p failed (status $?)\n"; next }
        open my $in, "<", $f or next; my @l = <$in>; close $in;
        unless (-s $f) { print $E "timed out; $sample $p produced nothing\n"; next }
        my ($i) = grep { $l[$_] =~ /^Sort by top of stack/ } 0 .. $#l;
        my @x; if (defined $i) { for my $j ($i .. $#l) { last if @x && $l[$j] =~ /^\s*$/ || $l[$j] =~ /^Binary Images/; push @x, $l[$j] } } else { @x = @l }
        @x = @x[0 .. 149] if @x > 150;
        print $E "timed out; sample of pid $p ($f):\n", @x, "\n";
      }
    }
    # PIPE is ignored from before the STOP until after $E is closed: a closed log must not kill us while the group is
    # stopped. Set here, in the handler, never before the fork: an ignored signal would survive the exec into the test.
    local $SIG{ALRM} = sub { if ($sampling) { $SIG{PIPE} = "IGNORE"; sample_group(); close $E if $E && fileno($E) != 2 } kill "KILL", -$pid; waitpid $pid, 0; exit 142 };
    # a signal that would end us while the group is stopped (sample_group) must end the group too
    for my $sig (qw(INT TERM HUP)) { $SIG{$sig} = sub { kill "KILL", -$pid; exit 128 + ($sig eq "INT" ? 2 : $sig eq "HUP" ? 1 : 15) } }
    alarm $t; waitpid $pid, 0; my $st = $?; alarm 0;
    kill "KILL", -$pid;   # whatever the test left in the group (a crash orphans StdlibUnittest children)
    $? = $st;
    exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' "$TIMEOUT" "$SAMPLING" "$@"
}
# reason LABEL RC : the failure text for run LABEL that exited RC
reason() { if [ "$2" = 142 ]; then echo "$1 timed out after $TIMEOUT s"; else echo "$1 exited non-zero"; fi; }
exec 3>&2   # (limited writes its samples here: a run's own stderr is captured)
SAMPLING=1
OUT="$(mktemp "${TMPDIR:-/tmp}/selftest-out.XXXXXX")"
trap 'rm -f "$OUT"' EXIT
trap 'exit 1' HUP INT TERM
matches() {
  [ -n "$chk" ] || return 0
  m_label="$1"
  set --; while IFS= read -r a; do set -- "$@" "$a"; done < "$chk.args"
  SAMPLING=0   # (sampling a timed-out FileCheck says nothing about the test)
  frc=0; fcerr="$(limited "$FC" "$@" "$PWD/$chk.swift" < "$OUT" 2>&1 >/dev/null)" || frc=$?
  SAMPLING=1
  [ "$frc" = 0 ] || { ok=0; why="$m_label: output does not match $chk.swift (FileCheck exited $frc)"; diag="$fcerr"; }
}

MODE="${1:-quick}"
pass=0; fail=0; failed=""
if [ "$MODE" = "--loads" ]; then
  # What the runtime pkg ships is read off the prefix itself, so a later layer needs no edit here.
  # dyld prints the path as it opened it (maybe through a symlink, maybe bin/../lib), so compare physical dirs.
  RTDIR="$PREFIX/lib/swift"; RTDIR_P="$(cd -P "$RTDIR" && pwd)"; SUPDIR="$(pwd -P)/lib"
  shipped="$(cd "$RTDIR" && ls -1 libswift*.dylib 2>/dev/null || :)"
  CXXDIR="$PREFIX/../libcxx22/lib"; CXXDIR_P="$(cd -P "$CXXDIR" 2>/dev/null && pwd || echo "$CXXDIR")"
fi
# run_one <test> <runs> <Guard Malloc runs> : runs one test as MODE says; counts and names it
run_one() {
  t="$1"; runs="$2"; gmruns="$3"; ok=1; why=""; diag=""; chk=""; sink=/dev/null
  case "$t" in
    upstream/bin/*) chk="upstream/check/${t##*/}"; chk="${chk%-Onone}"; [ -f "$chk.args" ] && sink="$OUT" || chk="" ;;
  esac
  if [ -n "$chk" ] && [ ! -x "$FC" ]; then
    ok=0; why="no FileCheck at $FC to check this test's output"; label=""
  elif [ "$MODE" = "--loads" ]; then
    # DYLD_PRINT_LIBRARIES goes to stderr (10.9's dyld; modern ones too).
    rc=0; err="$(limited DYLD_PRINT_LIBRARIES=1 "./$t" 2>&1 >"$sink")" || rc=$?
    [ "$rc" = 0 ] || { ok=0; why="$(reason "run 1 of 1" "$rc") with DYLD_PRINT_LIBRARIES=1"; }
    [ "$ok" = 0 ] || matches "run 1 of 1"
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
        # An OS image (/usr/lib, /System) is the OS's own libswift*, never a stray copy of ours: modern dyld maps
        # libswiftPrespecialized into any process that links libswiftCore. 10.9 has none, so the real gate never
        # sees one, and what the runtime ships (above) stays strict. Everything else must be the bundle's.
        case "$dir" in /usr/lib|/usr/lib/*|/System/*) continue ;; esac
        [ "$dir" = "$SUPDIR" ] || { ok=0; why="$lib loaded from $p, not from the bundle's $SUPDIR"; }
      fi
    done
    # A test that printed no libswiftCore load (no DYLD output read, say) proved nothing about where it loads from.
    [ "$ok" = 0 ] || [ "$core" = 1 ] || { ok=0; why="no libswiftCore.dylib loaded from $RTDIR (DYLD_PRINT_LIBRARIES showed none)"; }
    # spec: INGREDIENTS.md "One C++ runtime" -- one libc++ of the family's in the process, libcxx22's, besides
    #       the OS's own /usr/lib one, which 10.9's libobjc loads. dyld prints nothing when it hands out an image
    #       it already has, and `unloaded:` when it drops a copy it mapped. It maps a file once per process, so the
    #       same file printed again is another process (a test that spawns itself passes DYLD_PRINT_LIBRARIES on)
    #       or a reload, never a second copy: count files, each loaded minus unloaded, under its physical path.
    if [ "$ok" = 1 ]; then
      cxx="$(printf '%s\n' "$err" | sed -n 's/^\([^/]*\)\(\/[^ ]*\/libc++\.1\.dylib\).*$/\1 \2/p' | grep -v -e ' /usr/lib/' -e ' /System/' || :)"
      kept="$(printf '%s\n' "$cxx" | while IFS= read -r l; do
          [ -n "$l" ] || continue
          p="${l##* }"; d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd || dirname "$p")"
          if [ "${l#*unloaded}" != "$l" ]; then echo "- $d"; else echo "+ $d"; fi
        done | awk '{ s = substr($0, 1, 1); n[substr($0, 3)] += (s == "+") ? 1 : -1 } END { for (f in n) if (n[f] > 0) print f }')"
      nk="$(printf '%s\n' "$kept" | grep -c -v '^$' || :)"
      if [ "$nk" != 1 ]; then ok=0; why="$nk libc++.1.dylib images besides the OS's stayed loaded, not 1:$(printf '%s' "$cxx" | tr '\n' ';')"
      elif [ "$kept" != "$CXXDIR_P" ]; then ok=0; why="libc++.1.dylib did not load from $CXXDIR:$(printf '%s' "$cxx" | tr '\n' ';')"
      fi
    fi
    label="loads"
  elif [ "$MODE" = "--gate" ]; then
    n=0
    while [ "$n" -lt "$runs" ]; do
      rc=0; limited "./$t" >"$sink" 2>/dev/null || rc=$?
      [ "$rc" = 0 ] || { ok=0; why="$(reason "run $((n + 1)) of $runs" "$rc")"; break; }
      matches "run $((n + 1)) of $runs"; [ "$ok" = 1 ] || break
      n=$((n + 1))
    done
    g=0
    while [ "$ok" = 1 ] && [ "$g" -lt "$gmruns" ]; do
      # libgmalloc announces itself on stderr ("GuardMalloc[pid]: ...") on 10.9 and on modern macOS
      # alike; its absence means the run was not guarded, which must not read as a pass.
      rc=0; err="$(MallocScribble=1 MallocGuardEdges=1 limited DYLD_INSERT_LIBRARIES="$GMALLOC" "./$t" 2>&1 >"$sink")" || rc=$?
      [ "$rc" = 0 ] || { ok=0; why="$(reason "Guard Malloc run $((g + 1)) of $gmruns" "$rc")"; break; }
      case "$err" in
        *'GuardMalloc['*) ;;
        *) ok=0; why="Guard Malloc did not load ($GMALLOC)"; break ;;
      esac
      matches "Guard Malloc run $((g + 1)) of $gmruns"; [ "$ok" = 1 ] || break
      g=$((g + 1))
    done
    label="${runs}x + ${gmruns}x Guard Malloc"
  else
    rc=0; limited "./$t" >"$sink" 2>/dev/null || rc=$?
    [ "$rc" = 0 ] || { ok=0; why="$(reason "run 1 of 1" "$rc")"; }
    [ "$ok" = 0 ] || matches "run 1 of 1"
    label="run"
  fi
  [ -z "$chk" ] || label="$label, output checked"
  if [ "$ok" = 1 ]; then
    printf '  PASS (%s): %s\n' "$label" "$name"; pass=$((pass + 1))
  else
    printf '  FAIL: %s -- %s\n' "$name" "$why"; fail=$((fail + 1)); failed="$failed $name"
    [ -z "$diag" ] || printf '%s\n' "$diag" | sed -n '1,20s/^/    /p'
  fi
}
for t in bin/*; do
  [ -f "$t" ] && [ -x "$t" ] || continue
  name="$(basename "$t")"
  run_one "$t" "$RUNS" "$GMALLOC_RUNS"
done
# Upstream's own tests (make-selftest.sh's SELFTEST_SUPPORT), after this repo's: fewer runs each, as
# there are many more of them and each runs a whole suite (INGREDIENTS.md's gate paragraph sizes it).
TIMEOUT="$UPTIMEOUT"   # (limited and reason read it)
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
