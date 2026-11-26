#!/bin/sh
# platform: macOS-only -- builds Mach-O fixtures with -dynamiclib and loads libgmalloc.dylib
# usage: sh tests/selftest-gate-test.sh
#   Exercises tests/run-selftest.sh against small C fixtures: a clean program, one that exits 1,
#   one whose heap overrun only Guard Malloc catches, one that outlives SELFTEST_TIMEOUT, and
#   (--loads) programs that load the runtime's libswift*.dylib from the prefix or from elsewhere, or none (most
#   print the dyld lines they model, so the host's own Swift cannot leak in);
#   and a bundle's upstream/bin/, which runs after bin/, SELFTEST_UPSTREAM_RUNS times plus one Guard Malloc run,
#   each run under SELFTEST_UPSTREAM_TIMEOUT instead of SELFTEST_TIMEOUT; one with an upstream/check/<name>.args
#   passes only when a fake FileCheck (SELFTEST_FILECHECK) accepts each run's stdout.
set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
command -v cc >/dev/null 2>&1 || { echo "no cc -- skipping"; exit 77; }
[ -f /usr/lib/libgmalloc.dylib ] || { echo "no /usr/lib/libgmalloc.dylib -- skipping"; exit 77; }

T="$(mktemp -d "${TMPDIR:-/tmp}/selftest-gate.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

printf 'int main(void){return 0;}\n' > "$T/ok.c"
printf 'int main(void){return 1;}\n' > "$T/bad.c"
printf '#include <stdlib.h>\nint main(void){char *p=malloc(16); volatile char c=p[16]; (void)c; free(p); return 0;}\n' > "$T/overrun.c"
printf 'int f(void){return 0;}\n' > "$T/notgm.c"
cc -o "$T/ok" "$T/ok.c"; cc -o "$T/bad" "$T/bad.c"; cc -O0 -o "$T/overrun" "$T/overrun.c"
cc -dynamiclib -o "$T/notgmalloc.dylib" "$T/notgm.c"
# A fake runtime prefix holding real dylibs (--loads reads what dyld loads), and strays of the same names.
printf 'int core_f(void){return 0;}\n' > "$T/core.c"; printf 'int darwin_f(void){return 0;}\n' > "$T/darwin.c"
printf 'int support_f(void){return 0;}\n' > "$T/support.c"
printf '#include <unistd.h>\nint main(void){sleep(5); return 0;}\n' > "$T/sleeper.c"
mkdir -p "$T/prefix/lib/swift" "$T/stray" "$T/supportlib"
cc -dynamiclib -install_name @rpath/libswiftCore.dylib -o "$T/prefix/lib/swift/libswiftCore.dylib" "$T/core.c"
cc -dynamiclib -install_name @rpath/libswiftDarwin.dylib -o "$T/prefix/lib/swift/libswiftDarwin.dylib" "$T/darwin.c"
cc -dynamiclib -install_name @rpath/libswiftDarwin.dylib -o "$T/stray/libswiftDarwin.dylib" "$T/darwin.c"
cc -dynamiclib -install_name @rpath/libswiftTestSupport.dylib -o "$T/supportlib/libswiftTestSupport.dylib" "$T/support.c"
cc -dynamiclib -install_name @rpath/libswiftTestSupport.dylib -o "$T/stray/libswiftTestSupport.dylib" "$T/support.c"
printf 'int core_f(void);\nint main(void){return core_f();}\n' > "$T/useCore.c"
printf 'int core_f(void); int darwin_f(void);\nint main(void){return core_f()+darwin_f();}\n' > "$T/useBoth.c"
printf 'int core_f(void); int support_f(void);\nint main(void){return core_f()+support_f();}\n' > "$T/useSupport.c"
cc -o "$T/sleeper" "$T/sleeper.c"
# forker: a child that outlives it (as StdlibUnittest's child processes do), writing its pid first.
printf '%s\n' '#include <stdio.h>' '#include <stdlib.h>' '#include <unistd.h>' \
  'int main(void){pid_t p=fork(); if(p==0){sleep(30); return 0;} FILE *f=fopen(getenv("SELFTEST_PIDFILE"),"w"); fprintf(f,"%d\n",(int)p); fclose(f); sleep(5); return 0;}' > "$T/forker.c"
cc -o "$T/forker" "$T/forker.c"
# crasher: the same child, but it itself exits non-zero at once (a crash), leaving the child behind.
sed 's/sleep(5); return 0;/return 3;/' "$T/forker.c" > "$T/crasher.c"
cc -o "$T/crasher" "$T/crasher.c"
# counter: appends its own name to $SELFTEST_COUNT on each run, so a case can count runs and their order.
printf '%s\n' '#include <stdio.h>' '#include <stdlib.h>' \
  'int main(int c, char **v){FILE *f=fopen(getenv("SELFTEST_COUNT"),"a"); if(!f) return 2; fprintf(f,"%s\n",v[0]); fclose(f); return 0;}' > "$T/counter.c"
cc -o "$T/counter" "$T/counter.c"
printf '%s\n' '#include <stdio.h>' \
  'int main(void){puts("to stdout"); fflush(stdout); fputs("to stderr\n", stderr); return 0;}' > "$T/talker.c"
sed 's/return 0;/return 3;/' "$T/talker.c" > "$T/talk3.c"
cc -o "$T/talker" "$T/talker.c"; cc -o "$T/talk3" "$T/talk3.c"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" > "$FAKE_FC_DIR/argv"; cat > "$FAKE_FC_DIR/stdin"' \
  'echo call >> "$FAKE_FC_DIR/calls"; [ -z "${FAKE_FC_ERR:-}" ] || echo "$FAKE_FC_ERR" >&2; exit "${FAKE_FC_RC:-0}"' > "$T/fakefc"
chmod +x "$T/fakefc"; mkdir -p "$T/fc"
# The --loads fixtures print, as dyld would under DYLD_PRINT_LIBRARIES, the loads they model, and link no
# libswift* themselves: a real program that links libswiftCore loads whatever else the host's dyld adds, and
# macOS 26's maps the OS's libswiftPrespecialized and, through it, /usr/lib/swift/libswiftCore into it,
# which 10.9 (no OS Swift) never does. The real-binary cases further down run only where the host adds none.
# sim <name> <line>... : a fixture that writes each line to stderr, "@exe@" as its own physical bin/ dir.
sim() {
  n="$1"; shift
  { printf '%s\n' '#include <libgen.h>' '#include <limits.h>' '#include <stdio.h>' '#include <stdlib.h>' '#include <string.h>' \
      'static void line(const char *d, const char *s){const char *a=strstr(s,"@exe@");' \
      '  if(a) fprintf(stderr,"%.*s%s%s\n",(int)(a-s),s,d,a+5); else fprintf(stderr,"%s\n",s);}' \
      'int main(int c, char **v){char r[PATH_MAX]; const char *d=realpath(v[0],r)?dirname(r):"."; (void)c;'
    for l in "$@"; do printf '  line(d,"%s");\n' "$l"; done
    printf '  return 0;}\n'; } > "$T/$n.c"
  cc -o "$T/$n" "$T/$n.c"
}
# Probe the host once: does its dyld put an OS Swift image into a plain C program that links no Swift? On macOS 26+
# it does (system libraries link Swift), so DYLD_PRINT_LIBRARIES names libswift* whatever a fixture does and --loads
# cannot be exercised here; 10.9 has no OS Swift, and vm-test runs the real --loads check there. The env var is a
# test-only hook that injects such a line, to rehearse that host (CI) on any Mac.
HOST_SWIFT="$( { DYLD_PRINT_LIBRARIES=1 "$T/ok" 2>&1 >/dev/null; [ -z "${SELFTEST_GATE_TEST_FAKE_OS_SWIFT:-}" ] || echo "dyld[1]: <UUID> /usr/lib/swift/libswiftCore.dylib"; } | grep libswift || :)"
SKIP_WHY="the host's dyld loads the OS Swift runtime into every process (macOS 26+); --loads is exercised on 10.9 by vm-test"
CORE_LINE="dyld: loaded: $T/prefix/lib/swift/libswiftCore.dylib"   # 10.9's dyld's form
# loads_ok: Core from the prefix. loads_stray: Darwin from a stray dir (Core from the prefix).
# support_ok / support_stray: Core from the prefix, a non-shipped libswift* from the bundle's lib/ or a stray dir.
sim loads_ok "$CORE_LINE"
sim loads_stray "$CORE_LINE" "dyld: loaded: $T/stray/libswiftDarwin.dylib"
sim support_ok "$CORE_LINE" "dyld: loaded: @exe@/../lib/libswiftTestSupport.dylib"
sim support_stray "$CORE_LINE" "dyld: loaded: $T/stray/libswiftTestSupport.dylib"
# os_support / os_shipped: loads_ok plus, in a modern dyld's form, an OS libswift* image.
sim os_support "dyld[1]: <UUID> $T/prefix/lib/swift/libswiftCore.dylib" "dyld[1]: <UUID> /usr/lib/libswiftPrespecialized.dylib"
sim os_shipped "dyld[1]: <UUID> $T/prefix/lib/swift/libswiftCore.dylib" "dyld[1]: <UUID> /usr/lib/libswiftCore.dylib"
sim up_core "$CORE_LINE"
sim up_support "$CORE_LINE" "dyld: loaded: @exe@/../../lib/libswiftTestSupport.dylib"
# real_*: real programs linking the fake runtime, for the cases that take dyld's own output.
cc -o "$T/real_ok" "$T/useCore.c" -L"$T/prefix/lib/swift" -lswiftCore -Wl,-rpath,"$T/prefix/lib/swift"
cc -o "$T/real_stray" "$T/useBoth.c" -L"$T/stray" -lswiftDarwin -L"$T/prefix/lib/swift" -lswiftCore \
  -Wl,-rpath,"$T/stray" -Wl,-rpath,"$T/prefix/lib/swift"
cc -o "$T/real_support" "$T/useSupport.c" -L"$T/supportlib" -lswiftTestSupport -L"$T/prefix/lib/swift" -lswiftCore \
  -Wl,-rpath,@executable_path/../lib -Wl,-rpath,"$T/prefix/lib/swift"

# bundle $1.. = fixtures to put in a fresh bundle's bin/, or its upstream/bin/ as up:<fixture>, or chk:<name> for an
# upstream/check/<name>.args (two FileCheck options, one holding a space) and .swift; prints the bundle dir
bundle() {
  b="$(mktemp -d "$T/bundle.XXXXXX")"; mkdir -p "$b/bin"
  cp "$REPO/tests/run-selftest.sh" "$b/"
  for f in "$@"; do
    case "$f" in
      up:*) mkdir -p "$b/upstream/bin"; cp "$T/${f#up:}" "$b/upstream/bin/" ;;
      chk:*) mkdir -p "$b/upstream/check"
        printf '%s\n' '--check-prefix=CHECK' '--implicit-check-not=to stderr' > "$b/upstream/check/${f#chk:}.args"
        printf '// CHECK: to stdout\n' > "$b/upstream/check/${f#chk:}.swift" ;;
      *) cp "$T/$f" "$b/bin/" ;;
    esac
  done
  mkdir -p "$b/lib"; cp "$T/supportlib/libswiftTestSupport.dylib" "$b/lib/"
  printf '%s\n' "$b"
}
RUNS=3
FC="$T/fakefc"
run() {  # $1 = bundle, rest = args; runs from / so the script must find its own bin/; sets rc, out
  b="$1"; shift
  rc=0; out="$(cd / && SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS="$RUNS" SELFTEST_FILECHECK="$FC" FAKE_FC_DIR="$T/fc" \
    sh "$b/run-selftest.sh" "$@" 2>&1)" || rc=$?
}
fcreset() { rm -f "$T/fc/argv" "$T/fc/stdin" "$T/fc/calls"; }

echo "-- no runtime installed at the prefix: SKIP"
b="$(bundle ok)"; rc=0; out="$(SWIFT_RUNTIME_PREFIX="$T/nowhere" sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 77 ] || fail "expected 77 with no runtime, got $rc: $out"

echo "-- quick mode, all pass"
run "$(bundle ok)"; [ "$rc" = 0 ] || fail "quick ok: rc=$rc: $out"
case "$out" in *'ALL PASS'*) ;; *) fail "quick ok: no ALL PASS: $out" ;; esac

echo "-- gate, all pass (and Guard Malloc confirmed)"
run "$(bundle ok)" --gate; [ "$rc" = 0 ] || fail "gate ok: rc=$rc: $out"

echo "-- gate, one test exits 1"
run "$(bundle ok bad)" --gate; [ "$rc" = 1 ] || fail "gate bad: rc=$rc: $out"
case "$out" in *'FAIL: bad'*) ;; *) fail "gate bad: failure not named: $out" ;; esac

echo "-- an overrun passes quick mode but the gate catches it under Guard Malloc"
run "$(bundle overrun)"; [ "$rc" = 0 ] || fail "quick overrun should pass: rc=$rc: $out"
run "$(bundle overrun)" --gate; [ "$rc" = 1 ] || fail "gate overrun: rc=$rc: $out"
case "$out" in *'Guard Malloc run'*) ;; *) fail "gate overrun: not attributed to Guard Malloc: $out" ;; esac

echo "-- a Guard Malloc that does not load fails the gate"
b="$(bundle ok)"; rc=0
out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS=2 SELFTEST_GMALLOC="$T/notgmalloc.dylib" sh "$b/run-selftest.sh" --gate 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "non-gmalloc insert: rc=$rc: $out"
case "$out" in *'Guard Malloc did not load'*) ;; *) fail "non-gmalloc insert: wrong reason: $out" ;; esac

echo "-- an empty bin/ fails"
run "$(bundle)"; [ "$rc" = 1 ] || fail "empty bin: rc=$rc: $out"

echo "-- no bin/ at all (the repo's own tests/, as run-repo-tests.sh runs it): SKIP"
b="$(mktemp -d "$T/bundle.XXXXXX")"; cp "$REPO/tests/run-selftest.sh" "$b/"
run "$b"; [ "$rc" = 77 ] || fail "no bin/: rc=$rc: $out"
case "$out" in *'not a self-test bundle (no bin/)'*) ;; *) fail "no bin/: wrong reason: $out" ;; esac

echo "-- a non-numeric SELFTEST_RUNS is refused"
RUNS=abc; run "$(bundle ok)" --gate; RUNS=3
[ "$rc" = 1 ] || fail "SELFTEST_RUNS=abc: rc=$rc: $out"
case "$out" in *'SELFTEST_RUNS'*) ;; *) fail "SELFTEST_RUNS=abc: not named: $out" ;; esac

echo "-- an unknown argument is refused, not run as quick mode"
run "$(bundle ok)" -gate; [ "$rc" = 2 ] || fail "-gate: rc=$rc: $out"
case "$out" in *'usage: run-selftest.sh [--gate|--loads]'*) ;; *) fail "-gate: no usage line: $out" ;; esac

echo "-- an inherited DYLD_* variable is refused"
# platform: modern macOS's SIP strips DYLD_* from the environment of /bin/sh itself, so the
#           refusal is observable only where a DYLD_ variable reaches a sh child (10.9: no SIP).
if [ "$(DYLD_LIBRARY_PATH=/x sh -c 'printf %s "${DYLD_LIBRARY_PATH:-}"')" = /x ]; then
  b="$(bundle ok)"; rc=0
  out="$(cd / && DYLD_LIBRARY_PATH="$T/nowhere" SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS="$RUNS" \
    sh "$b/run-selftest.sh" --gate 2>&1)" || rc=$?
  [ "$rc" = 1 ] || fail "DYLD_LIBRARY_PATH set: rc=$rc: $out"
  case "$out" in
    *'refusing to run with DYLD_* set: DYLD_LIBRARY_PATH'*) ;;
    *) fail "DYLD_LIBRARY_PATH set: wrong reason: $out" ;;
  esac
else
  echo "   DYLD_* stripped by this OS; refusal case not exercised"
fi
echo "-- a run that outlives SELFTEST_TIMEOUT fails, within seconds, naming the timeout"
b="$(bundle sleeper)"; rc=0; start="$(date +%s)"
out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_TIMEOUT=1 SELFTEST_RUNS=3 sh "$b/run-selftest.sh" 2>&1)" || rc=$?
took=$(( $(date +%s) - start ))
[ "$rc" = 1 ] || fail "timeout: rc=$rc: $out"
[ "$took" -le 3 ] || fail "timeout: took ${took}s, wanted <= 3: $out"
case "$out" in *'run 1 of 1 timed out after 1 s'*) ;; *) fail "timeout: not named: $out" ;; esac
rc=0; out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_TIMEOUT=1 SELFTEST_RUNS=3 sh "$b/run-selftest.sh" --gate 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "gate timeout: rc=$rc: $out"
case "$out" in *'run 1 of 3 timed out after 1 s'*) ;; *) fail "gate timeout: not named: $out" ;; esac

echo "-- a run that times out takes its children with it (StdlibUnittest's would spin on, orphaned)"
b="$(bundle forker)"; rc=0
out="$(SELFTEST_PIDFILE="$T/pid" SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_TIMEOUT=1 sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "forker: rc=$rc: $out"
case "$out" in *'run 1 of 1 timed out after 1 s'*) ;; *) fail "forker: not a timeout: $out" ;; esac
kid="$(cat "$T/pid")"; [ -n "$kid" ] || fail "forker wrote no pid"
if kill -0 "$kid" 2>/dev/null; then kill -9 "$kid"; fail "the timed-out run's child $kid outlived it"; fi

echo "-- a run that exits on its own takes its children with it too (a crash leaves none behind)"
rm -f "$T/pid"; b="$(bundle crasher)"; rc=0
out="$(SELFTEST_PIDFILE="$T/pid" SWIFT_RUNTIME_PREFIX="$T/prefix" sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "crasher: rc=$rc: $out"
case "$out" in *'exited non-zero'*) ;; *) fail "crasher: exit not reported as before: $out" ;; esac
kid="$(cat "$T/pid")"; [ -n "$kid" ] || fail "crasher wrote no pid"
if kill -0 "$kid" 2>/dev/null; then kill -9 "$kid"; fail "the crashed run's child $kid outlived it"; fi

echo "-- upstream/bin/ runs under SELFTEST_UPSTREAM_TIMEOUT, bin/ under SELFTEST_TIMEOUT"
b="$(bundle ok up:sleeper)"; rc=0
out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_TIMEOUT=1 SELFTEST_UPSTREAM_TIMEOUT=10 sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 0 ] || fail "an upstream run within SELFTEST_UPSTREAM_TIMEOUT but past SELFTEST_TIMEOUT failed: rc=$rc: $out"
rc=0; out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_TIMEOUT=10 SELFTEST_UPSTREAM_TIMEOUT=1 sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "an upstream run past SELFTEST_UPSTREAM_TIMEOUT passed: rc=$rc: $out"
case "$out" in *'FAIL: upstream/bin/sleeper -- run 1 of 1 timed out after 1 s'*) ;; *) fail "upstream timeout: not named: $out" ;; esac
b="$(bundle sleeper)"; rc=0
out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_TIMEOUT=1 SELFTEST_UPSTREAM_TIMEOUT=10 sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "SELFTEST_UPSTREAM_TIMEOUT reached bin/: rc=$rc: $out"
for v in abc 0 -5; do
  b="$(bundle ok)"; rc=0
  out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_UPSTREAM_TIMEOUT="$v" sh "$b/run-selftest.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || fail "SELFTEST_UPSTREAM_TIMEOUT='$v': rc=$rc: $out"
  case "$out" in *SELFTEST_UPSTREAM_TIMEOUT*) ;; *) fail "SELFTEST_UPSTREAM_TIMEOUT='$v': not named: $out" ;; esac
done

echo "-- a SELFTEST_TIMEOUT that is not a positive integer is refused"
for v in abc 0 -5; do
  b="$(bundle ok)"; rc=0
  out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_TIMEOUT="$v" sh "$b/run-selftest.sh" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || fail "SELFTEST_TIMEOUT='$v': rc=$rc: $out"
  case "$out" in *SELFTEST_TIMEOUT*) ;; *) fail "SELFTEST_TIMEOUT='$v': not named: $out" ;; esac
done

echo "-- no perl: refuse to run rather than run without a timeout"
b="$(bundle ok)"; rc=0
out="$(SELFTEST_PERL="$T/no-such-perl" SWIFT_RUNTIME_PREFIX="$T/prefix" sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "no perl: rc=$rc: $out"
case "$out" in *'no perl'*) ;; *) fail "no perl: not named: $out" ;; esac

echo "-- --loads: libswift* the runtime ships must load from the prefix"
if [ -n "$HOST_SWIFT" ]; then echo "   skipped: $SKIP_WHY"; else
run "$(bundle loads_ok)" --loads; [ "$rc" = 0 ] || fail "loads_ok: rc=$rc: $out"
case "$out" in *'ALL PASS'*) ;; *) fail "loads_ok: no ALL PASS: $out" ;; esac
run "$(bundle loads_stray)" --loads; [ "$rc" = 1 ] || fail "loads_stray: rc=$rc: $out"
case "$out" in *'FAIL: loads_stray'*"/stray/libswiftDarwin.dylib"*) ;; *) fail "loads_stray: binary and path not named: $out" ;; esac

echo "-- --loads: other libswift* (test support) must load from the bundle's lib/"
run "$(bundle support_ok)" --loads; [ "$rc" = 0 ] || fail "support_ok: rc=$rc: $out"
run "$(bundle support_stray)" --loads; [ "$rc" = 1 ] || fail "support_stray: rc=$rc: $out"
case "$out" in *'FAIL: support_stray'*) ;; *) fail "support_stray: not named: $out" ;; esac

echo "-- --loads: an OS libswift* image (/usr/lib) is fine for non-shipped names, never for what the runtime ships"
run "$(bundle os_support)" --loads; [ "$rc" = 0 ] || fail "os_support: rc=$rc: $out"
run "$(bundle os_shipped)" --loads; [ "$rc" = 1 ] || fail "os_shipped: rc=$rc: $out"
case "$out" in *'FAIL: os_shipped'*'/usr/lib/libswiftCore.dylib'*) ;; *) fail "os_shipped: not named: $out" ;; esac
fi

echo "-- --loads, real programs: dyld's own output read the same way (only where the host's dyld adds no OS Swift)"
os_swift="$(DYLD_PRINT_LIBRARIES=1 "$T/real_ok" 2>&1 >/dev/null | sed -n 's/^[^/]*\(\/[^ ]*libswift[^ ]*\.dylib\).*$/\1/p' \
  | grep -E '^/(usr/lib|System)/' || :)"
if [ -n "$HOST_SWIFT" ]; then
  echo "   skipped: $SKIP_WHY"
elif [ -z "$os_swift" ]; then
  run "$(bundle real_ok real_support)" --loads; [ "$rc" = 0 ] || fail "real_ok: rc=$rc: $out"
  run "$(bundle real_stray)" --loads; [ "$rc" = 1 ] || fail "real_stray: rc=$rc: $out"
  case "$out" in *'FAIL: real_stray'*"/stray/libswiftDarwin.dylib"*) ;; *) fail "real_stray: binary and path not named: $out" ;; esac
else
  echo "   this host's dyld loads OS Swift into a program that links libswiftCore ($(echo $os_swift)); not exercised"
fi

echo "-- --loads: a test that loads no libswiftCore from the prefix fails (it checked nothing)"
if [ -z "$HOST_SWIFT" ]; then
run "$(bundle ok)" --loads; [ "$rc" = 1 ] || fail "--loads passed a test that loads no libswift*: rc=$rc: $out"
case "$out" in *'FAIL: ok'*'libswiftCore'*) ;; *) fail "--loads did not say libswiftCore was not loaded: $out" ;; esac
else echo "   skipped: $SKIP_WHY"; fi

echo "-- upstream/bin/: --gate runs each SELFTEST_UPSTREAM_RUNS times and once under Guard Malloc, after bin/"
b="$(bundle counter up:counter)"; mv "$b/upstream/bin/counter" "$b/upstream/bin/upcounter"
rc=0; out="$(cd / && SELFTEST_COUNT="$T/count" SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS=3 SELFTEST_UPSTREAM_RUNS=2 \
  sh "$b/run-selftest.sh" --gate 2>&1)" || rc=$?
[ "$rc" = 0 ] || fail "gate with upstream: rc=$rc: $out"
[ "$(grep -c '/bin/counter$' "$T/count")" = 13 ] || fail "bin/counter ran $(grep -c '/bin/counter$' "$T/count") times, not 3 + 10: $(cat "$T/count")"
[ "$(grep -c '/upstream/bin/upcounter$' "$T/count")" = 3 ] || fail "upstream's ran $(grep -c 'upcounter$' "$T/count") times, not 2 + 1: $(cat "$T/count")"
[ "$(sed -n '$p' "$T/count" | sed 's|.*/||')" = upcounter ] && [ "$(sed -n 1p "$T/count" | sed 's|.*/||')" = counter ] \
  || fail "upstream/bin/ did not run after bin/: $(cat "$T/count")"
case "$out" in *'PASS (2x + 1x Guard Malloc): upstream/bin/upcounter'*) ;; *) fail "upstream's pass not reported as such: $out" ;; esac
case "$out" in *'passed=2  failed=0'*) ;; *) fail "not two passes counted: $out" ;; esac
rm -f "$T/count"

echo "-- SELFTEST_NO_GMALLOC: a listed test runs its plain runs, no Guard Malloc run, and says so; the rest as before"
b="$(bundle counter up:counter)"; mv "$b/upstream/bin/counter" "$b/upstream/bin/upcounter"
cp "$b/upstream/bin/upcounter" "$b/upstream/bin/upcounter-Onone"   # unlisted, and the listed name is its prefix
rc=0; out="$(cd / && SELFTEST_COUNT="$T/count" SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS=3 SELFTEST_UPSTREAM_RUNS=2 \
  SELFTEST_NO_GMALLOC="upstream/bin/upcounter" sh "$b/run-selftest.sh" --gate 2>&1)" || rc=$?
[ "$rc" = 0 ] || fail "no-gmalloc: rc=$rc: $out"
[ "$(grep -c '/bin/counter$' "$T/count")" = 13 ] || fail "no-gmalloc: bin/counter ran $(grep -c '/bin/counter$' "$T/count") times, not 3 + 10"
[ "$(grep -c '/upstream/bin/upcounter$' "$T/count")" = 2 ] || fail "no-gmalloc: upstream's ran $(grep -c 'upcounter$' "$T/count") times, not 2"
[ "$(grep -c '/upstream/bin/upcounter-Onone$' "$T/count")" = 3 ] || fail "no-gmalloc: the unlisted -Onone ran $(grep -c 'upcounter-Onone$' "$T/count") times, not 2 + 1"
case "$out" in *'PASS (2x, Guard Malloc skipped by SELFTEST_NO_GMALLOC): upstream/bin/upcounter'*) ;; *) fail "no-gmalloc: the skip not said: $out" ;; esac
case "$out" in *'PASS (2x + 1x Guard Malloc): upstream/bin/upcounter-Onone'*) ;; *) fail "no-gmalloc: the unlisted -Onone not guarded: $out" ;; esac
rm -f "$T/count"

echo "-- SELFTEST_NO_GMALLOC: a name that is no test here is refused (a stale list must not pass unseen)"
run_env() { rc=0; out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS=2 SELFTEST_NO_GMALLOC="$2" sh "$1/run-selftest.sh" --gate 2>&1)" || rc=$?; }
run_env "$(bundle ok)" "upstream/bin/nosuch"
[ "$rc" = 1 ] || fail "no-gmalloc stale: rc=$rc: $out"
case "$out" in *'SELFTEST_NO_GMALLOC'*'upstream/bin/nosuch'*) ;; *) fail "no-gmalloc stale: not named: $out" ;; esac
# Names that exist as files but are not how the PASS line names a test, and a glob, which must not expand.
for n in bin/ok run-selftest.sh 'upstream/bin/*' 'upstream/bin/../bin/ok' .; do
  run_env "$(bundle ok up:ok)" "$n"
  case "$rc:$out" in 1:*"SELFTEST_NO_GMALLOC names $n,"*) ;; *) fail "no-gmalloc: '$n' not refused: rc=$rc: $out" ;; esac
done
run_env "$(bundle ok)" "ok"; [ "$rc" = 0 ] || fail "no-gmalloc: a bin/ test by its bare name refused: rc=$rc: $out"
case "$out" in *'PASS (2x, Guard Malloc skipped by SELFTEST_NO_GMALLOC): ok'*) ;; *) fail "no-gmalloc: bin/ok not skipped: $out" ;; esac

echo "-- upstream/bin/: a failure there fails the gate, named; quick mode runs it once"
run "$(bundle ok up:bad)" --gate; [ "$rc" = 1 ] || fail "upstream bad: rc=$rc: $out"
case "$out" in *'FAIL: upstream/bin/bad'*) ;; *) fail "upstream bad: not named: $out" ;; esac
b="$(bundle counter up:counter)"; rc=0
out="$(cd / && SELFTEST_COUNT="$T/count" SWIFT_RUNTIME_PREFIX="$T/prefix" sh "$b/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 0 ] && [ "$(grep -c . "$T/count")" = 2 ] || fail "quick mode with upstream: rc=$rc, runs $(cat "$T/count"): $out"
rm -f "$T/count"

echo "-- upstream/bin/: --loads holds them to the same rule (support from the bundle's lib/)"
if [ -z "$HOST_SWIFT" ]; then
run "$(bundle loads_ok up:up_core up:up_support)" --loads; [ "$rc" = 0 ] || fail "upstream loads: rc=$rc: $out"
case "$out" in *'upstream/bin/up_support'*) ;; *) fail "upstream loads: upstream/bin/ not checked: $out" ;; esac
else echo "   skipped: $SKIP_WHY"; fi

echo "-- a SELFTEST_UPSTREAM_RUNS that is not a positive integer is refused"
b="$(bundle ok)"; rc=0
out="$(SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_UPSTREAM_RUNS=x sh "$b/run-selftest.sh" --gate 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "SELFTEST_UPSTREAM_RUNS=x: rc=$rc: $out"
case "$out" in *SELFTEST_UPSTREAM_RUNS*) ;; *) fail "SELFTEST_UPSTREAM_RUNS=x: not named: $out" ;; esac

echo "-- upstream/check/: a run whose output FileCheck matches passes, checked"
fcreset; b="$(bundle ok up:talker chk:talker)"; run "$b"
[ "$rc" = 0 ] || fail "check match: rc=$rc: $out"
case "$out" in *'PASS (run, output checked): upstream/bin/talker'*) ;; *) fail "check match: not reported as checked: $out" ;; esac
[ "$(cat "$T/fc/argv")" = "$(printf '%s\n' '--check-prefix=CHECK' '--implicit-check-not=to stderr' "$(cd "$b" && pwd)/upstream/check/talker.swift")" ] \
  || fail "check match: FileCheck's argv: $(cat "$T/fc/argv")"
[ "$(cat "$T/fc/stdin")" = "to stdout" ] || fail "check match: FileCheck read, not the test's stdout alone: $(cat "$T/fc/stdin")"

echo "-- upstream/check/: a mismatch fails, naming the check and FileCheck's status"
fcreset; rc=0; out="$(cd / && SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_FILECHECK="$FC" FAKE_FC_DIR="$T/fc" FAKE_FC_RC=1 \
  sh "$(bundle ok up:talker chk:talker)/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "check mismatch: rc=$rc: $out"
case "$out" in
  *'FAIL: upstream/bin/talker -- run 1 of 1: output does not match upstream/check/talker.swift (FileCheck exited 1)'*) ;;
  *) fail "check mismatch: wrong reason: $out" ;;
esac

echo "-- upstream/check/: a mismatch shows FileCheck's diagnostics after the FAIL line, at most 20 of them"
fcreset; rc=0; out="$(cd / && SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_FILECHECK="$FC" FAKE_FC_DIR="$T/fc" FAKE_FC_RC=1 \
  FAKE_FC_ERR="$(printf 'check.swift:1:11: error: CHECK: expected string not found in input\n'; i=2; while [ "$i" -le 30 ]; do echo "dump line $i"; i=$((i + 1)); done)" \
  sh "$(bundle ok up:talker chk:talker)/run-selftest.sh" 2>&1)" || rc=$?
[ "$rc" = 1 ] || fail "check diagnostics: rc=$rc: $out"
case "$out" in
  *'(FileCheck exited 1)
    check.swift:1:11: error: CHECK: expected string not found in input'*) ;;
  *) fail "check diagnostics: FileCheck's error not shown, indented, after the FAIL line: $out" ;;
esac
case "$out" in *'dump line 20'*) ;; *) fail "check diagnostics: fewer than 20 lines shown: $out" ;; esac
case "$out" in *'dump line 21'*) fail "check diagnostics: more than 20 lines shown: $out" ;; esac

echo "-- upstream/check/: the exit status and the match are both required"
fcreset; run "$(bundle ok up:talk3 chk:talk3)"
[ "$rc" = 1 ] || fail "check status: rc=$rc: $out"
case "$out" in *'FAIL: upstream/bin/talk3 -- run 1 of 1 exited non-zero'*) ;; *) fail "check status: wrong reason: $out" ;; esac

echo "-- upstream/check/: an empty output is still checked"
fcreset; rc=0; out="$(cd / && SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_FILECHECK="$FC" FAKE_FC_DIR="$T/fc" FAKE_FC_RC=1 \
  sh "$(bundle ok up:ok chk:ok)/run-selftest.sh" 2>&1)" || rc=$?
[ -f "$T/fc/argv" ] || fail "check empty: FileCheck not run on an empty output: $out"
[ "$rc" = 1 ] || fail "check empty: FileCheck's rc did not decide: rc=$rc: $out"
fcreset; run "$(bundle ok up:ok chk:ok)"; [ "$rc" = 0 ] && [ -f "$T/fc/argv" ] || fail "check empty, match: rc=$rc: $out"

echo "-- upstream/check/: no FileCheck to check with fails the test, never skips it"
FC=/nonexistent; run "$(bundle ok up:talker chk:talker)"; FC="$T/fakefc"
[ "$rc" = 1 ] || fail "no FileCheck: rc=$rc: $out"
case "$out" in *"FAIL: upstream/bin/talker -- no FileCheck at /nonexistent to check this test's output"*) ;; *) fail "no FileCheck: wrong reason: $out" ;; esac

echo "-- upstream/check/: --gate checks every run, the Guard Malloc one too"
fcreset; rc=0; out="$(cd / && SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS=2 SELFTEST_UPSTREAM_RUNS=3 SELFTEST_FILECHECK="$FC" \
  FAKE_FC_DIR="$T/fc" sh "$(bundle ok up:talker chk:talker)/run-selftest.sh" --gate 2>&1)" || rc=$?
[ "$rc" = 0 ] || fail "check gate: rc=$rc: $out"
[ "$(grep -c . "$T/fc/calls")" = 4 ] || fail "check gate: FileCheck ran $(grep -c . "$T/fc/calls") times, not 3 + 1: $out"
[ "$(cat "$T/fc/stdin")" = "to stdout" ] || fail "check gate: the Guard Malloc run's FileCheck read: $(cat "$T/fc/stdin")"
case "$out" in *'PASS (3x + 1x Guard Malloc, output checked): upstream/bin/talker'*) ;; *) fail "check gate: not reported as checked: $out" ;; esac
b="$(bundle ok up:talker chk:talker)"; rc=0
out="$(cd / && SWIFT_RUNTIME_PREFIX="$T/prefix" SELFTEST_RUNS=2 SELFTEST_UPSTREAM_RUNS=1 SELFTEST_GMALLOC="$T/notgmalloc.dylib" \
  SELFTEST_FILECHECK="$FC" FAKE_FC_DIR="$T/fc" sh "$b/run-selftest.sh" --gate 2>&1)" || rc=$?
case "$rc:$out" in 1:*'Guard Malloc did not load'*) ;; *) fail "check gate: an unguarded run passed: rc=$rc: $out" ;; esac

echo "-- upstream/check/: a test with no check runs as before, with no FileCheck"
fcreset; run "$(bundle ok up:talker)" --gate
[ "$rc" = 0 ] && [ ! -f "$T/fc/calls" ] || fail "no check: rc=$rc, FileCheck ran: $out"
case "$out" in *'output checked'*) fail "no check: reported as checked: $out" ;; esac
FC=/nonexistent; run "$(bundle ok up:talker)"; FC="$T/fakefc"
[ "$rc" = 0 ] || fail "no check, no FileCheck: rc=$rc: $out"

echo "-- upstream/check/: the -Onone build is checked against the same <name>"
fcreset; b="$(bundle ok up:talker chk:talker)"; cp "$b/upstream/bin/talker" "$b/upstream/bin/talker-Onone"; run "$b"
[ "$rc" = 0 ] && [ "$(grep -c . "$T/fc/calls")" = 2 ] || fail "-Onone: rc=$rc: $out"
case "$out" in *'PASS (run, output checked): upstream/bin/talker-Onone'*) ;; *) fail "-Onone: not checked: $out" ;; esac
[ "$(sed -n '$p' "$T/fc/argv")" = "$(cd "$b" && pwd)/upstream/check/talker.swift" ] || fail "-Onone: checked against $(sed -n '$p' "$T/fc/argv")"

echo "PASS"
