#!/usr/bin/env python3
# platform: host-agnostic -- python3, standard library only (run as python3 -I)
#   usage: upstream-tests.py survey <tree> <layer>
#          upstream-tests.py check <tree> <layer> <list>
#          upstream-tests.py compile-line <tree> <path>
#          Upstream Swift's own tests for a layer of the API stack, as the 10.9 gate runs them (spec: "Upstream
#          tests"; the spike's 50-survey-tests.py, productized). <tree> is the pinned swift source; <layer> is
#          darwin, objectivec or concurrency.
#            survey        prints every candidate, sorted: each .swift or .swift.gyb under test/stdlib,
#                          test/Concurrency/Runtime and validation-test/stdlib (no Inputs/) with a RUN: line,
#                          as lit runs only those, that the layer's classifier picks. Darwin: it imports Darwin
#                          (or Glibc), or is one of upstream's Darwin-named files (tgmath, POSIX, PrintFloat,
#                          ...); ObjectiveC: it imports ObjectiveC or REQUIRES objc_interop (not Observation's);
#                          Concurrency: test/Concurrency/Runtime, or REQUIRES concurrency.
#            check         fails unless <list> names every candidate exactly once, as `include <path>` or
#                          `exclude <path> -- <reason>`, names no path that is not one, and each include's
#                          compile-line translates. build.sh's step 5b runs it on each tests/upstream/*.list,
#                          so a Swift bump that adds a test, or gives an included test a RUN: form, flag or
#                          REQUIRES:/UNSUPPORTED: this script does not know, stops the build. (A change
#                          to a flag's value it allows, or to the test's source, does not: the gate runs it.)
#            compile-line  prints, one argument per line, the swiftc arguments lit would compile the test
#                          with, less the source, -o, -target/-sdk (the toolchain's defaults) and the
#                          optimization level (make-selftest.sh builds each test at -O and at -Onone): lit's
#                          -swift-version 4 and -define-availability list (utils/availability-macros.def,
#                          each StdlibDeploymentTarget clamped to 10.9, as lit clamps it to the OS it runs
#                          on), then the RUN: line's own flags, then lit's -module-name main for the
#                          %target-run-simple-* forms. It knows %target-run-simple-swift[(<flags>)],
#                          %target-run-simple-swiftgyb[(<flags>)], %target-run-stdlib-swift[(<flags>)] (lit's
#                          simple form plus -disable-access-control), and the explicit %empty-directory /
#                          [%gyb %s -o] / %target-build-swift / %target-codesign / %target-run sequence (each
#                          optionally behind %line-directive), and %target-swift-<x.y>-abi-triple. It refuses,
#                          saying why, anything else: FileCheck (no 10.9 pkg ships it), another substitution,
#                          another command, arguments or input or a redirection handed to the test (but for
#                          upstream's stray -strict-concurrency=complete, which the test ignores), more than
#                          one executable step or build, a second source, a compiler flag outside an explicit
#                          allowlist (PLAIN_FLAGS, VALUED_FLAGS), a REQUIRES: that does not hold on 10.9 or an
#                          UNSUPPORTED: that does (FEATURES; macosx and back-deployment count as true); so the
#                          list must exclude that test.
#          Exit 0, 1 (check failed, or compile-line refused), 2 usage.
import os
import re
import shlex
import sys

DEPLOYMENT = "10.9"   # pins.env's DEPLOYMENT: what StdlibDeploymentTarget is clamped to, as lit clamps it to the OS it runs on
ROOTS = ["test/stdlib", "test/Concurrency/Runtime", "validation-test/stdlib"]
LAYERS = ["darwin", "objectivec", "concurrency"]


class Refused(Exception):
    pass


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def has(pat, text):
    return re.search(pat, text, re.M) is not None


def requires(text):
    return " ".join(re.findall(r"^\s*//\s*REQUIRES:\s*(.*)$", text, re.M))


def layers_of(path, text):
    req = requires(text)
    out = []
    if has(r"^\s*(@[_a-zA-Z]+\s+)*import\s+(Darwin|Glibc)\b", text) or \
            re.search(r"stdlib/(Darwin|POSIX|tgmath|MachError|Glibc|Platform|PrintFloat|FloatingPoint)", path, re.I):
        out.append("darwin")
    if (has(r"^\s*(@[_a-zA-Z]+\s+)*import\s+ObjectiveC\b", text) or "objc_interop" in req) and "/Observation/" not in path:
        out.append("objectivec")
    if path.startswith("test/Concurrency/Runtime/") or re.search(r"\bconcurrency\b", req):
        out.append("concurrency")
    return out


def survey(tree, layer):
    found = []
    for root in ROOTS:
        for d, dirs, files in os.walk(os.path.join(tree, root)):
            dirs[:] = [x for x in dirs if x != "Inputs"]
            for f in files:
                if not (f.endswith(".swift") or f.endswith(".swift.gyb")):
                    continue
                p = os.path.join(d, f)
                text = read(p)
                if not has(r"^\s*//\s*RUN:", text):
                    continue
                rel = os.path.relpath(p, tree)
                if layer in layers_of(rel, text):
                    found.append(rel)
    return sorted(found)


def run_commands(text):
    """lit's RUN: lines, a trailing backslash joining a line to the next, split at &&."""
    cmds, cur = [], None
    for line in re.findall(r"^\s*//\s*RUN:(.*)$", text, re.M):
        line = line.strip()
        cont = line.endswith("\\")
        if cont:
            line = line[:-1].strip()
        cur = line if cur is None else cur + " " + line
        if not cont:
            cmds.append(cur)
            cur = None
    if cur is not None:
        cmds.append(cur)
    out = []
    for c in cmds:
        out.extend(x.strip() for x in c.split("&&") if x.strip())
    return out


def availability(tree):
    """lit.cfg's load_availability_macros and availability_macro_to_current, for macOS at DEPLOYMENT."""
    def newer(a, b):
        x = [int(n) for n in a.split(".")]
        y = [int(n) for n in b.split(".")]
        n = max(len(x), len(y))
        return x + [0] * (n - len(x)) > y + [0] * (n - len(y))
    args, abi = [], {}
    for line in read(os.path.join(tree, "utils/availability-macros.def")).splitlines():
        if re.fullmatch(r"\s*(#.*)?", line):
            continue
        args += ["-Xfrontend", "-define-availability", "-Xfrontend", line]
        m = re.match(r"\s*SwiftStdlib\s+([0-9.]+)\s*:\s*(.*)$", line)
        if not m:
            continue
        vers, spec = m.group(1), m.group(2)
        by = dict(re.findall(r"(\w+) ([0-9.]+)", spec))
        mac = by.get("macOS", by.get("anyAppleOS"))
        cur = "StdlibDeploymentTarget %s:%s" % (vers, spec)
        if mac is not None and mac != "9999" and newer(mac, DEPLOYMENT):
            cur = "StdlibDeploymentTarget %s:macOS %s" % (vers, DEPLOYMENT)
        args += ["-Xfrontend", "-define-availability", "-Xfrontend", cur]
        if mac is not None:
            abi[vers] = mac
    return args, abi


# The compiler flags a RUN: line may carry, and no others: what the included tests use today, and the brief's
# known forms. A flag outside it is refused, so a Swift bump that gives an included test -enable-experimental-
# feature <something else>, -Xllvm, -sanitize=... or -D... stops `check` until a reviewer extends the list.
PLAIN_FLAGS = {"-parse-as-library", "-parse-stdlib", "-O", "-Onone", "-Ounchecked", "-g"}
VALUED_FLAGS = {   # flag -> what its value must match
    "-swift-version": r"[0-9]+(\.[0-9]+)?",
    "-module-name": r"[A-Za-z_][A-Za-z0-9_]*",
    "-enable-experimental-feature": r"Extern",
    "-Xfrontend": r"-disable-availability-checking",
    "-target": r"x86_64-apple-macosx[0-9.]+",   # only reachable through %target-swift-<x.y>-abi-triple
}


def translate(words, abi):
    sub = []
    for w in words:
        m = re.fullmatch(r"%target-swift-([0-9]+\.[0-9]+)-abi-triple", w)
        if m:
            v = abi.get(m.group(1))
            if v is None or v == "9999":
                raise Refused("RUN uses %s, which names no macOS release" % w)
            sub.append("x86_64-apple-macosx%s" % v)
            continue
        s = re.search(r"%[\w.-]+", w)
        if s:
            raise Refused("RUN uses %s" % s.group(0))
        sub.append(w)
    out, i = [], 0
    while i < len(sub):
        w = sub[i]
        if w in PLAIN_FLAGS:
            out.append(w)
        elif w in VALUED_FLAGS:
            if i + 1 >= len(sub) or not re.fullmatch(VALUED_FLAGS[w], sub[i + 1]):
                raise Refused("RUN uses %s %s, which no included test is known to need" % (w, sub[i + 1] if i + 1 < len(sub) else ""))
            out += [w, sub[i + 1]]
            i += 1
        else:
            raise Refused("RUN uses the flag %s, which no included test is known to need" % w)
        i += 1
    return out


# lit's feature set for this gate (10.9 x86_64, a Release 1 stdlib built -O with reflection and the Extern
# feature on): REQUIRES/UNSUPPORTED expressions are evaluated against it. A name it does not list is false.
FEATURES = {"executable_test", "objc_interop", "OS=macosx", "VENDOR=apple", "CPU=x86_64", "optimized_stdlib",
            "reflection", "swift_feature_Extern", "stress_test"}
# UNSUPPORTED terms that are true of any back-deployed runtime: this runtime is one.
BACKDEPLOY = re.compile(r"back[-_]?deploy", re.I)


def lit_eval(expr, true_names, what):
    toks = re.findall(r"&&|\|\||!|\(|\)|[-+=._a-zA-Z0-9]+|\S", expr)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take():
        pos[0] += 1
        return toks[pos[0] - 1]

    def expr_():
        v = term()
        while peek() == "||":
            take()
            v = term() or v
        return v

    def term():
        v = unary()
        while peek() == "&&":
            take()
            v = unary() and v
        return v

    def unary():
        t = peek()
        if t is None:
            raise Refused("%s: does not parse (%s)" % (what, expr))
        if t == "!":
            take()
            return not unary()
        if t == "(":
            take()
            v = expr_()
            if peek() != ")":
                raise Refused("%s: does not parse (%s)" % (what, expr))
            take()
            return v
        if re.fullmatch(r"[-+=._a-zA-Z0-9]+", t):
            take()
            return t in true_names or bool(what == "UNSUPPORTED" and BACKDEPLOY.search(t))
        raise Refused("%s: does not parse (%s)" % (what, expr))
    v = expr_()
    if pos[0] != len(toks):
        raise Refused("%s: does not parse (%s)" % (what, expr))
    return v


def conditions(text):
    """REQUIRES: every line must hold on 10.9; UNSUPPORTED: none may (lit's meaning, at this gate's features)."""
    for e in re.findall(r"^\s*//\s*REQUIRES:\s*(.*)$", text, re.M):
        if not lit_eval(e, FEATURES, "REQUIRES"):
            raise Refused("REQUIRES: %s does not hold on 10.9" % e.strip())
    for e in re.findall(r"^\s*//\s*UNSUPPORTED:\s*(.*)$", text, re.M):
        if lit_eval(e, FEATURES, "UNSUPPORTED"):
            raise Refused("UNSUPPORTED: %s holds on 10.9" % e.strip())


def split(s):
    try:
        return shlex.split(s)
    except ValueError as e:
        raise Refused("RUN does not parse (%s)" % e)


REDIRECT = re.compile(r"^(\||<|>|[0-9]>|&>|2>&1)")
SIMPLE = re.compile(r"^%target-run-(simple|stdlib)-swift(gyb)?(?![\w-])")


def tail_refusal(rest):
    rest = rest.strip()
    if not rest or rest == "-strict-concurrency=complete":
        # (upstream's POSIXErrorCode writes this after a bare %target-run-simple-swift, where lit hands it to
        # the test binary, not the compiler: StdlibUnittest ignores it, so the run without it is the same run.)
        return None
    if REDIRECT.match(rest):
        return "RUN redirects the test's input or output (%s)" % rest
    return "RUN hands the test arguments (%s)" % rest


def compile_line(tree, path):
    text = read(os.path.join(tree, path))
    cmds = run_commands(text)
    if not cmds:
        raise Refused("no RUN: line")
    conditions(text)
    if "FileCheck" in " ".join(cmds):
        raise Refused("needs FileCheck, which no 10.9 pkg ships")
    base, abi = availability(tree)
    base = ["-swift-version", "4"] + base
    runs, builds, flags, gyb_out, built = 0, 0, None, None, None
    for c in cmds:
        m = re.match(r"^%line-directive\s+\S+\s+--\s+(.*)$", c)
        if m:
            c = m.group(1).strip()
        m = SIMPLE.match(c)
        if m:
            rest = c[m.end():]
            inner = ""
            if rest.startswith("("):
                depth, i = 0, 0
                for i, ch in enumerate(rest):
                    depth += (ch == "(") - (ch == ")")
                    if depth == 0:
                        break
                if depth != 0:
                    raise Refused("RUN has an unbalanced %s(" % m.group(0))
                inner, rest = rest[1:i], rest[i + 1:]
            why = tail_refusal(rest)
            if why:
                raise Refused(why)
            if m.group(2) and not path.endswith(".gyb"):
                raise Refused("RUN gybs a file that is no .gyb")
            flags = translate(split(inner), abi) + ["-module-name", "main"]
            if m.group(1) == "stdlib":
                flags += ["-Xfrontend", "-disable-access-control"]
            runs += 1
            builds += 1
            continue
        if re.fullmatch(r"%empty-directory\(%t\)|mkdir -p %t", c):
            continue
        m = re.fullmatch(r"%gyb %s -o (%t/[\w.-]+\.swift)", c)
        if m and path.endswith(".gyb"):
            gyb_out = m.group(1)
            continue
        w = split(c)
        if w[0] == "%target-build-swift":
            builds += 1
            rest, out, sources = [], None, []
            i = 1
            while i < len(w):
                if w[i] == "-o" and i + 1 < len(w):
                    out = w[i + 1]
                    i += 2
                    continue
                if w[i] == "%s" or (gyb_out is not None and w[i] == gyb_out):
                    sources.append(w[i])
                elif re.search(r"\.(swift|o|m|c|a|dylib)$", w[i]) and not w[i].startswith("-"):
                    raise Refused("RUN compiles more than the test file (%s)" % w[i])
                else:
                    rest.append(w[i])
                i += 1
            if sources != [gyb_out if path.endswith(".gyb") else "%s"]:
                raise Refused("RUN's %target-build-swift does not compile the test file itself")
            if out is None or not out.startswith("%t"):
                raise Refused("RUN's %target-build-swift writes no %t executable")
            flags, built = translate(rest, abi), out
            continue
        if w[0] == "%target-codesign":
            continue
        if w[0] == "%target-run":
            runs += 1
            if len(w) < 2 or w[1] != built:
                raise Refused("RUN runs something it did not build")
            why = tail_refusal(c.split(w[1], 1)[1])
            if why:
                raise Refused(why)
            continue
        if w[0].startswith("%"):
            raise Refused("RUN uses %s" % re.match(r"%[\w-]+", w[0]).group(0))
        raise Refused("RUN runs %s" % w[0])
    if runs > 1:
        raise Refused("more than one executable step")
    if builds > 1:
        raise Refused("RUN builds more than one product")
    if runs == 0 or flags is None:
        raise Refused("RUN runs no executable")
    return base + flags


def check(tree, layer, listfile):
    cands = set(survey(tree, layer))
    seen, errs = {}, []
    for n, line in enumerate(read(listfile).splitlines(), 1):
        if re.fullmatch(r"\s*(#.*)?", line):
            continue
        m = re.fullmatch(r"(include|exclude) (\S+)(?: -- (.*))?", line)
        if not m:
            errs.append("%s:%d: unknown line: %s" % (listfile, n, line))
            continue
        verb, p, why = m.group(1), m.group(2), (m.group(3) or "").strip()
        if p in seen:
            errs.append("%s: listed more than once (lines %d and %d)" % (p, seen[p], n))
            continue
        seen[p] = n
        if p not in cands:
            errs.append("%s: not a %s candidate" % (p, layer))
            continue
        if verb == "exclude" and not why:
            errs.append('%s: an exclude needs " -- <reason>"' % p)
        if verb == "include":
            if m.group(3) is not None:
                errs.append("%s: an include takes no reason" % p)
            try:
                compile_line(tree, p)
            except Refused as e:
                errs.append("%s: an include whose compile-line refuses: %s" % (p, e))
    for p in sorted(cands - set(seen)):
        errs.append("%s: not in the list" % p)
    for e in errs:
        print(e, file=sys.stderr)
    if errs:
        print("upstream-tests.py: %s does not cover the %s candidates of %s (above)" % (listfile, layer, tree), file=sys.stderr)
        return 1
    print("%s: %d candidates, %d included" % (listfile, len(cands),
          sum(1 for line in read(listfile).splitlines() if line.startswith("include "))))
    return 0


def usage():
    print("usage: upstream-tests.py survey <tree> <layer> | check <tree> <layer> <list> | compile-line <tree> <path>",
          file=sys.stderr)
    return 2


def main(argv):
    if len(argv) < 3:
        return usage()
    cmd, tree = argv[1], argv[2]
    if not os.path.isfile(os.path.join(tree, "utils/availability-macros.def")):
        print("upstream-tests.py: %s is no swift tree (no utils/availability-macros.def)" % tree, file=sys.stderr)
        return 2
    if cmd in ("survey", "check"):
        if len(argv) != (4 if cmd == "survey" else 5) or argv[3] not in LAYERS:
            return usage()
        if cmd == "survey":
            for p in survey(tree, argv[3]):
                print(p)
            return 0
        return check(tree, argv[3], argv[4])
    if cmd == "compile-line" and len(argv) == 4:
        try:
            for a in compile_line(tree, argv[3]):
                print(a)
        except Refused as e:
            print("upstream-tests.py: %s: %s" % (argv[3], e), file=sys.stderr)
            return 1
        return 0
    return usage()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
