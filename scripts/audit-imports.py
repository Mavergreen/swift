#!/usr/bin/env python3
# platform: macOS-only -- reads Mach-O with dyld_info; runs on a modern Mac only (CI's cross job and a
#           maintainer's), never on OS X 10.9, so python3 is allowed here: build-toolchain.sh --host arm64
#           calls it, and the x86_64 build and everything 10.9 runs never do.
#   usage: audit-imports.py <macho> <sdk>
#          Fails unless every NON-weak symbol <macho> imports from a Swift library in /usr/lib/swift, from
#          libc++ or from libobjc is exported, for <macho>'s own arch, by <sdk>'s .tbd for that library.
#          The cross toolchain's swift-frontend links the swift.org toolchain's libswiftCore (built for
#          macOS 13) ahead of the SDK's, so its link proves nothing about macOS 11; this audit against
#          the pinned MacOSX11.3.sdk is the check. A weak import may be absent (the compiler guards it).
#          A Swift library the SDK has no .tbd for fails, unless every import from it is weak.
import re
import subprocess
import sys

TBD_LISTS = ("symbols", "weak-symbols", "thread-local-symbols", "objc-classes", "objc-eh-types", "objc-ivars")


def tbd_exports(path, target):
    """Every symbol a .tbd (every document in it) exports or re-exports for <target>, e.g. arm64-macos."""
    text = open(path).read()
    out = set()
    section = None      # the top-level key we are in (exports, reexports, ...)
    targets = []        # the current export block's targets
    key = None          # the list key being read, possibly across lines
    buf = ""
    for line in text.splitlines():
        if line.startswith("---"):
            section, targets, key = None, [], None
            continue
        top = re.match(r"^([A-Za-z-]+):", line)
        if top:
            section, key = top.group(1), None
            continue
        if section not in ("exports", "reexports"):
            continue
        m = re.match(r"^\s*(-\s+)?([a-z-]+):\s*(.*)$", line)
        if m and key is None:
            if m.group(1):
                targets = []
            key, buf = m.group(2), m.group(3)
        elif key is not None:
            buf += " " + line.strip()
        if key is not None and "]" in buf:
            items = [s.strip().strip("'\"") for s in buf.strip().strip("[]").split(",")]
            items = [s for s in items if s]
            if key == "targets":
                targets = items
            elif key in TBD_LISTS and target in targets:
                if key == "objc-classes":
                    out.update(p + s for s in items for p in ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"))
                elif key == "objc-eh-types":
                    out.update("_OBJC_EHTYPE_$_" + s for s in items)
                elif key == "objc-ivars":
                    out.update("_OBJC_IVAR_$_" + s for s in items)
                else:
                    out.update(items)
            key, buf = None, ""
    return out


def dyld_info(flag, macho):
    return subprocess.run(["dyld_info", flag, macho], capture_output=True, text=True, check=True).stdout


def leaf(install_name):
    """dyld_info's (from <leaf>): the file name without .dylib and without a trailing version letter."""
    base = install_name.rsplit("/", 1)[-1]
    base = re.sub(r"\.dylib$", "", base)
    return re.sub(r"\.[A-Z0-9]$", "", base)


def main():
    if len(sys.argv) != 3:
        print("usage: audit-imports.py <macho> <sdk>", file=sys.stderr)
        return 2
    macho, sdk = sys.argv[1], sys.argv[2].rstrip("/")
    deps = dyld_info("-dependents", macho)
    arch = re.search(r"\[(\w+)\]:", deps)
    if not arch:
        print(f"audit-imports: cannot read {macho}'s arch", file=sys.stderr)
        return 1
    target = arch.group(1) + "-macos"
    audited = {}  # leaf -> the SDK .tbd its imports are checked against
    for m in re.finditer(r"(/usr/lib/\S+\.dylib)", deps):
        name = m.group(1)
        if name.startswith("/usr/lib/swift/") or leaf(name) in ("libc++", "libobjc"):
            audited[leaf(name)] = sdk + re.sub(r"\.dylib$", ".tbd", name)
    if "libswiftCore" not in audited:
        print(f"audit-imports: {macho} does not link /usr/lib/swift/libswiftCore.dylib -- nothing to audit is itself a failure", file=sys.stderr)
        return 1
    hard, weak = {}, []
    for line in dyld_info("-imports", macho).splitlines():
        # platform: dyld_info puts a fixup index (0x0000) before each import of a binary that uses
        #           chained fixups (a macOS 12+ minimum, like the test's fixtures), and none otherwise.
        m = re.match(r"\s+(?:0x[0-9a-f]+\s+)?(\S+)\s+(\[weak-import\]\s+)?\(from (\S+)\)", line)
        if m and m.group(3) in audited:
            if m.group(2):
                weak.append(f"{m.group(1)} ({m.group(3)})")
            else:
                hard.setdefault(m.group(3), []).append(m.group(1))
    bad = 0
    for lib in sorted(audited):
        imps = hard.get(lib, [])
        try:
            exported = tbd_exports(audited[lib], target)
        except OSError:
            exported = set()
            if imps:
                print(f"{lib}: {len(imps)} imports, and {sdk} has no {audited[lib]}")
                bad += len(imps)
                continue
        missing = [s for s in imps if s not in exported]
        print(f"{lib}: {len(imps)} imports, {len(missing)} not exported for {target} by {sdk.rsplit('/', 1)[-1]}")
        for s in missing:
            print("   missing:", s)
        bad += len(missing)
    print("weak imports (allowed absent):", ", ".join(weak) if weak else "none")
    return 1 if bad else 0


sys.exit(main())
