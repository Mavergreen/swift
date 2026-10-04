#!/bin/sh
# platform: macOS-only -- runs pkgutil
# lib.sh — the build root and the swift.org installer check, shared by every build script (sourced
# after pins.env, which supplies TOOLCHAIN_SIGNER), and the helpers build.sh builds the runtime with on
# either host (the dirs it hands the compilers, the prefix maps, the preflight's Mach-O readers). One
# copy, so no two scripts disagree about where the build lives or what a trusted installer is.

# platform: a family checkout may live on NFS, where a build cost 11.16s wall / 25% CPU against
#           2.96s / 88% on local disk with identical user time -- the whole difference is I/O wait.
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
# A relative root is made absolute here, once, before any script cds: build.sh cds into the root and
# then named paths under it relative to the new cwd ("run ./build-llvm.sh" after it had run). A root
# holding whitespace is refused: the compile and link flags that name it are split on whitespace by
# CMake, and the build failed in CMake's compiler probe after build-llvm.sh's 28 minutes.
case "$MAVERICKS_BUILD_ROOT" in /*) ;; *) MAVERICKS_BUILD_ROOT="$(pwd)/$MAVERICKS_BUILD_ROOT" ;; esac
[ "$(printf '%s' "$MAVERICKS_BUILD_ROOT" | tr -d ' \t\n')" = "$MAVERICKS_BUILD_ROOT" ] || {
  echo "lib.sh: MAVERICKS_BUILD_ROOT '$MAVERICKS_BUILD_ROOT' holds whitespace, which the build's flags cannot carry -- choose a root without" >&2
  return 1 2>/dev/null || exit 1; }
# work/ (sources and build trees), out/llvm (LLVM build support), cache/ (the swift.org pkg),
# payload/<pkg> (each pkg's install root -- pkgbuild ships everything in it, so no build tree may live
# there), build/updater, dist/ (release assets).
SWIFT_BUILD="$MAVERICKS_BUILD_ROOT/swift"

# verify_toolchain_signature <pkg> -- fail closed unless the installer is signed by the pinned
# identity. Replaces a per-version SHA256 pin: the identity holds across releases, so a Swift bump
# needs no human to paste a hash. Records the observed digest for provenance.
verify_toolchain_signature() {
  _pkg="$1"
  pkgutil --check-signature "$_pkg" > "$_pkg.sigcheck" 2>&1 || {
    echo "FAIL: $_pkg is not a validly signed installer" >&2; cat "$_pkg.sigcheck" >&2; return 1; }
  grep -Fq "$TOOLCHAIN_SIGNER" "$_pkg.sigcheck" || {
    echo "FAIL: signed, but not by the pinned identity" >&2
    echo "  expected: $TOOLCHAIN_SIGNER" >&2
    sed -n "s/^ *1\\. */  found:    /p" "$_pkg.sigcheck" >&2
    return 1; }
  echo "OK: signed by $TOOLCHAIN_SIGNER"
  echo "    sha256 (recorded, not pinned): $(shasum -a 256 "$_pkg" | awk '{print $1}')"
  rm -f "$_pkg.sigcheck"
}

# expand_toolchain <pkg> <dir> -- <dir> holds exactly <pkg>'s payload. Expanded again when <dir> came
# from another installer (a Swift bump in a reused build root) or has lost any file: macOS's $TMPDIR
# cleaner deletes files under the build root, and a half-deleted toolchain fails far from the cause
# ("missing required module 'SwiftShims'").
expand_toolchain() {
  _rec="$2.expanded"
  if [ -f "$_rec" ] && [ "$(sed -n 1p "$_rec")" = "$(basename "$1")" ] \
     && sed 1d "$_rec" | ( cd "$2" 2>/dev/null || exit 1
          while IFS= read -r _f; do [ -e "$_f" ] || [ -L "$_f" ] || exit 1; done ); then
    return 0
  fi
  rm -rf "$2" "$2.x" "$_rec"
  pkgutil --expand "$1" "$2.x" || return 1
  _payload="$(find "$2.x" -name Payload | head -1)"
  [ -n "$_payload" ] || { echo "expand_toolchain: $1 has no payload" >&2; return 1; }
  mkdir -p "$2" && ditto -x -z "$_payload" "$2" || return 1
  # platform: a pkg built on a macOS 27 host lists AppleDouble ._* members for files carrying
  #           com.apple.provenance; ditto folds them into xattrs, so no such file exists to check for.
  { basename "$1"; lsbom -s "$(dirname "$_payload")/Bom" | grep -v '/\._'; } > "$_rec.tmp" || return 1
  rm -rf "$2.x"
  mv "$_rec.tmp" "$_rec"
}

# check_release_pin <what> <release> <tag> <sha> <repo-url> -- fail unless <release> is SWIFT_VERSION
# and <sha> is the commit <repo-url>'s <tag> names. Source code cut for another Swift release builds
# fine and is wrong, which no later gate can see; this refuses it before anything is fetched.
check_release_pin() {
  [ "$2" = "$SWIFT_VERSION" ] || {
    echo "FAIL: $1 is pinned at $3, but SWIFT_VERSION is $SWIFT_VERSION -- move its pins in pins.env" >&2; return 1; }
  # platform: git ls-remote lists an annotated tag twice, the tag object and then its peeled commit
  #           (refs/tags/T^{}); only the peeled one is comparable with a commit SHA.
  _sha="$(git ls-remote "$5" "refs/tags/$3" "refs/tags/$3^{}" \
    | awk -v t="refs/tags/$3" '{ sha[$2] = $1 } END { if ((t "^{}") in sha) print sha[t "^{}"]; else print sha[t] }')"
  [ -n "$_sha" ] || { echo "FAIL: $5 has no tag $3" >&2; return 1; }
  [ "$_sha" = "$4" ] || { echo "FAIL: $1's pinned commit is $4, but $5's $3 is $_sha" >&2; return 1; }
}

# prefix_map_flags c|swift <root> -- flags sending <root>, by both of its spellings, to /mavergreen-build,
# so no path of the machine that built it survives in the runtime: `c` prints -ffile-prefix-map words for
# CMAKE_C_FLAGS and CMAKE_CXX_FLAGS, `swift` a CMake list of -file-prefix-map pairs for
# SWIFT_EXPERIMENTAL_EXTRA_FLAGS. Both spellings, physical first: a compiler records the path it was
# handed, and CMake hands it sources by their resolved path (macOS's $TMPDIR is /var/..., a link into
# /private/var/...), so a map of one spelling misses the other (Demangler.cpp's __FILE__ did). The
# logical one is normalized as CMake normalizes it ($TMPDIR ends in /, so a root under it holds //).
prefix_map_flags() {
  case "$2" in /*) ;; *) echo "prefix_map_flags: '$2' is not an absolute path" >&2; return 1 ;; esac
  _pm_phys="$(CDPATH='' cd -P -- "$2" && pwd -P)" || { echo "prefix_map_flags: no directory '$2'" >&2; return 1; }
  _pm_log="$(CDPATH='' cd -L -- "$2" && pwd -L)" || return 1
  # CMake splits these flags on whitespace, so a spelling that holds any cannot be mapped.
  for _pm_s in "$_pm_phys" "$_pm_log"; do
    [ "$(printf '%s' "$_pm_s" | tr -d ' \t\n')" = "$_pm_s" ] || {
      echo "prefix_map_flags: '$_pm_s' holds whitespace, which a flag split on whitespace cannot carry" >&2; return 1; }
  done
  case "$1" in
    c) echo "-ffile-prefix-map=$_pm_phys=/mavergreen-build -ffile-prefix-map=$_pm_log=/mavergreen-build" ;;
    swift) echo "-file-prefix-map;$_pm_phys=/mavergreen-build;-file-prefix-map;$_pm_log=/mavergreen-build" ;;
    *) echo "prefix_map_flags: the kind is c or swift, not '$1'" >&2; return 2 ;;
  esac
}

# clang_resource_include <prefix> -- prints <prefix>/lib/clang/<v>/include, the ONE clang resource-header
# dir under <prefix>. None is refused, and so is more than one (a reused build root keeps the previous
# LLVM major's beside the new one, and picking either silently could pair a clang with the wrong
# headers), naming them.
clang_resource_include() {
  _cr_found=""; _cr_n=0
  for _cr_d in "$1"/lib/clang/*/include; do
    if [ -d "$_cr_d" ]; then _cr_found="$_cr_found${_cr_found:+ }$_cr_d"; _cr_n=$((_cr_n + 1)); fi
  done
  [ "$_cr_n" -eq 1 ] || {
    echo "$_cr_n clang resource dirs under $1/lib/clang, where one was expected (a stale LLVM major in a reused build root? remove it): $_cr_found" >&2
    return 1; }
  echo "$_cr_found"
}

# clang_resource_shim <clang-include-dir> <builtins-archive> <dir> -- lays out <dir> as a clang
# -resource-dir holding include -> <clang-include-dir> and lib/darwin/libclang_rt.osx.a ->
# <builtins-archive>, replacing whatever <dir> held. The runtime's link passes it, so the driver puts
# THAT archive where it puts its own, last, after -lSystem. Named earlier on the link line, the archive
# would supply ___divti3 and its three siblings, which libSystem supplies when it comes last.
clang_resource_shim() {
  for _cs_p in "$1" "$2" "$3"; do
    case "$_cs_p" in /*) ;; *) echo "clang_resource_shim: '$_cs_p' is not an absolute path" >&2; return 1 ;; esac
  done
  [ -d "$1" ] || { echo "clang_resource_shim: no clang resource headers at $1" >&2; return 1; }
  [ -f "$2" ] || { echo "clang_resource_shim: no builtins archive at $2" >&2; return 1; }
  rm -rf "$3" && mkdir -p "$3/lib/darwin" && ln -s "$1" "$3/include" \
    && ln -s "$2" "$3/lib/darwin/libclang_rt.osx.a"
}

# native_host_shim <toolchain-prefix> <dir> -- lays out <dir>/usr as the stdlib build's host toolchain on
# OS X 10.9, from an installed swift-toolchain, replacing whatever <dir> held. bin/swiftc and
# bin/swift-frontend are its BARE swift-frontend: the stdlib build passes its own -sdk, -target,
# -tools-directory and -runtime-compatibility-version, and the toolchain's bin/swiftc wrapper would add
# the 10.9 SDK, the installed runtime's rpath and an SDK fetch to every call. bin/clang and bin/clang++
# are its clang; bin/ld64.lld its lld, and bin/ld a script that execs it under that name (lld takes its
# Mach-O personality from its name). usr/lib is its lib: the stdlib's CMake derives <tools>/../lib paths.
native_host_shim() {
  for _ns_p in "$1" "$2"; do
    case "$_ns_p" in /*) ;; *) echo "native_host_shim: '$_ns_p' is not an absolute path" >&2; return 1 ;; esac
  done
  for _ns_f in bin/swift-frontend bin/clang bin/ld64.lld lib/swift; do
    [ -e "$1/$_ns_f" ] || { echo "native_host_shim: $1 has no $_ns_f -- is swift-toolchain installed there?" >&2; return 1; }
  done
  rm -rf "$2" && mkdir -p "$2/usr/bin" || return 1
  for _ns_n in swiftc swift-frontend; do ln -s "$1/bin/swift-frontend" "$2/usr/bin/$_ns_n" || return 1; done
  for _ns_n in clang clang++; do ln -s "$1/bin/clang" "$2/usr/bin/$_ns_n" || return 1; done
  ln -s "$1/bin/ld64.lld" "$2/usr/bin/ld64.lld" && ln -s "$1/lib" "$2/usr/lib" || return 1
  printf '#!/bin/sh\nexec "%s/bin/ld64.lld" "$@"\n' "$1" > "$2/usr/bin/ld" && chmod 755 "$2/usr/bin/ld"
}

# host_toolchain_release <toolchain-prefix> -- prints `<release> (<where it was read>)` for the Swift
# toolchain at <prefix>, and fails, saying why, unless <release> is one of SWIFT_VERSION's
# (<SWIFT_VERSION>-mavericks.N). The stdlib is coupled to its compiler: this checkout's sources compiled
# by another release's compiler fail far from the cause, or build a runtime CI never builds. The release
# is the receipt of the pkg that installed <prefix>/bin/swift-frontend (pkgutil --file-info), whichever
# pkg id that is, so the cross toolchain's is read as the native one's is. A copy that no pkg installed
# has no receipt: SWIFT_HOST_TOOLCHAIN_VERSION then declares its release, held to the same rule, and
# where there is a receipt it must agree with it.
host_toolchain_release() {
  _hr_info="$(pkgutil --file-info "$1/bin/swift-frontend")" || {
    echo "FAIL: pkgutil could not look up the receipt of $1/bin/swift-frontend" >&2; return 1; }
  _hr_v="$(printf '%s\n' "$_hr_info" | sed -n 's/^pkg-version: *//p' | sort -u)"
  _hr_id="$(printf '%s\n' "$_hr_info" | sed -n 's/^pkgid: *//p' | sort -u | tr '\n' ' ')"
  case "$_hr_v" in *'
'*) echo "FAIL: $1/bin/swift-frontend belongs to more than one release: $(printf '%s' "$_hr_v" | tr '\n' ' ')(pkgs ${_hr_id% })" >&2
    return 1 ;;
  esac
  _hr_how="pkg ${_hr_id% }"
  if [ -n "${SWIFT_HOST_TOOLCHAIN_VERSION:-}" ]; then
    if [ -z "$_hr_v" ]; then
      _hr_v="$SWIFT_HOST_TOOLCHAIN_VERSION"; _hr_how="declared by SWIFT_HOST_TOOLCHAIN_VERSION"
    elif [ "$_hr_v" != "$SWIFT_HOST_TOOLCHAIN_VERSION" ]; then
      echo "FAIL: SWIFT_HOST_TOOLCHAIN_VERSION says $SWIFT_HOST_TOOLCHAIN_VERSION, but the receipt of $1 ($_hr_how) says $_hr_v" >&2
      return 1
    fi
  fi
  [ -n "$_hr_v" ] || {
    echo "FAIL: no pkg installed $1/bin/swift-frontend, so its release is unknown -- install swift-toolchain's newest $SWIFT_VERSION release, or declare a copy's release with SWIFT_HOST_TOOLCHAIN_VERSION" >&2
    return 1; }
  case "$_hr_v" in
    "$SWIFT_VERSION"-?*) ;;
    *) echo "FAIL: the host toolchain at $1 is release $_hr_v ($_hr_how), but this checkout builds Swift $SWIFT_VERSION -- install swift-toolchain's newest $SWIFT_VERSION-mavericks.N release" >&2
       return 1 ;;
  esac
  printf '%s (%s)\n' "$_hr_v" "$_hr_how"
}

# host_inputs_stamp <swift-frontend> <clang> <builtins-archive> -- five lines, `<role> <sha256>`, for the
# host compiler, the host clang, the clang.cfg and clang++.cfg that clang reads (`<role> none` for one
# that is absent) and the builtins archive a stdlib build is configured with. Their bytes reach the
# runtime, yet the build cannot see them change: nothing in the stdlib's CMake depends on an external
# SWIFT_NATIVE_SWIFT_TOOLS_PATH compiler, no C++ object on its compiler's bytes or flags from a cfg, and
# no link on the archive -resource-dir names. clang reads <driver>.cfg from its real binary's directory,
# links resolved (the native host shim links the toolchain's clang), so the cfgs are looked for there.
# Fails, naming it, when one cannot be hashed.
host_inputs_stamp() {
  _hs_c="$2"; _hs_n=0
  while [ -L "$_hs_c" ]; do
    _hs_n=$((_hs_n + 1))
    [ "$_hs_n" -le 20 ] || { echo "host_inputs_stamp: too many links from $2" >&2; return 1; }
    _hs_l="$(readlink "$_hs_c")" || { echo "host_inputs_stamp: could not read the link $_hs_c" >&2; return 1; }
    case "$_hs_l" in /*) _hs_c="$_hs_l" ;; *) _hs_c="$(dirname "$_hs_c")/$_hs_l" ;; esac
  done
  _hs_d="$(dirname "$_hs_c")"
  for _hs_r in swift-frontend:"$1" clang:"$2" clang.cfg:"$_hs_d/clang.cfg" clang++.cfg:"$_hs_d/clang++.cfg" builtins:"$3"; do
    _hs_f="${_hs_r#*:}"
    case "${_hs_r%%:*}" in
      *.cfg) if [ ! -e "$_hs_f" ] && [ ! -L "$_hs_f" ]; then printf '%s none\n' "${_hs_r%%:*}"; continue; fi ;;
    esac
    [ -f "$_hs_f" ] || { echo "host_inputs_stamp: no $_hs_f" >&2; return 1; }
    _hs_s="$(shasum -a 256 < "$_hs_f" | awk '{ print $1 }')"
    [ "${#_hs_s}" -eq 64 ] || { echo "host_inputs_stamp: could not hash $_hs_f" >&2; return 1; }
    printf '%s %s\n' "${_hs_r%%:*}" "$_hs_s"
  done
}

# reuse_build_dir <dir> <stamp> -- keeps <dir> when its mavergreen-inputs.stamp holds exactly <stamp>;
# otherwise removes it, saying so (a dir with no stamp was built from inputs nobody recorded). The caller
# writes <stamp> there once it has configured <dir>. An empty <stamp> is refused: it would equal the
# empty read of a missing stamp.
reuse_build_dir() {
  [ -n "$2" ] || { echo "reuse_build_dir: an empty stamp for $1" >&2; return 1; }
  [ -d "$1" ] || return 0
  if [ "$(cat "$1/mavergreen-inputs.stamp" 2>/dev/null)" = "$2" ]; then return 0; fi
  echo "    removing $1: its host compiler, clang, clang.cfg or builtins archive changed, or went unrecorded"
  rm -rf "$1"
}

# macho_links_none_under <macho> <dir> -- fails, listing them, when <macho> links a library under <dir>.
# Fails too when otool cannot read <macho>'s libraries, or reads no libSystem, which every program links:
# on OS X 10.9 without the Command Line Tools, /usr/bin/otool is a stub that prints nothing, and an empty
# answer read as "nothing under <dir>" is a check that checked nothing.
macho_links_none_under() {
  _ml_out="$(otool -L "$1")" || { echo "FAIL: could not read the libraries $1 links (otool)" >&2; return 1; }
  printf '%s\n' "$_ml_out" | grep -q '/usr/lib/libSystem\.B\.dylib' || {
    echo "FAIL: otool read no libSystem from $1, so it read nothing $1 links" >&2; return 1; }
  if printf '%s\n' "$_ml_out" | grep -F "$2"; then
    echo "FAIL: $1 links a library from $2 (listed above)" >&2; return 1
  fi
}

# runtime_patches_unlisted <dir> <number>... -- prints each <dir>/*.patch whose number (the name up to its
# first -) is none of <number>..., and fails when there is one, or when <dir> holds no patch. build.sh
# applies an explicit list (a number can be retired: 0006 was), so a patch added without its entry would
# be skipped in silence, by a local build and by CI's alike.
runtime_patches_unlisted() {
  _rp_dir="$1"; shift
  _rp_n=0; _rp_bad=0
  for _rp_p in "$_rp_dir"/*.patch; do
    [ -f "$_rp_p" ] || continue
    _rp_n=$((_rp_n + 1)); _rp_num="${_rp_p##*/}"; _rp_num="${_rp_num%%-*}"
    case " $* " in *" $_rp_num "*) ;; *) printf '%s\n' "$_rp_p"; _rp_bad=1 ;; esac
  done
  [ "$_rp_n" -gt 0 ] || { echo "runtime_patches_unlisted: no patches in $_rp_dir" >&2; return 1; }
  [ "$_rp_bad" -eq 0 ]
}

# macho_minos <macho> -- the minimum macOS <macho> records. dyld_info when $DYLDINFO names it; else
# otool's LC_VERSION_MIN_MACOSX or LC_BUILD_VERSION (OS X 10.9 has no dyld_info). Prints nothing when
# the file records neither.
macho_minos() {
  macho_version "$1" | awk '{ print $1 }'   # the pipe's status is awk's, as before: a reader failure prints nothing
}

# macho_imports <macho> -- one line per symbol <macho> imports, `<symbol> [weak-import] (from <lib>)` for
# a weak one and `<symbol> (from <lib>)` otherwise: dyld_info -imports when $DYLDINFO names it, else nm
# (${NM:-nm}) -m -u rewritten to the same shape. Fails when the tool fails: an empty answer read as
# "imports nothing" is how a preflight passes having checked nothing.
macho_imports() {
  if [ -n "${DYLDINFO:-}" ]; then
    _mi_out="$("$DYLDINFO" -imports "$1")" || return 1
    printf '%s\n' "$_mi_out" | sed '1,2d; s/^ *//' | tr -s ' '
  else
    _mi_out="$("${NM:-nm}" -m -u "$1")" || return 1
    printf '%s\n' "$_mi_out" | sed -e 's/^ *(undefined) //' -e 's/^weak external \([^ ]*\)/\1 [weak-import]/' -e 's/^external //'
  fi
}

# toolchain_host_select x86_64|arm64 -- names what the toolchain that RUNS on that host is built in and
# shipped as, in six variables: TH_LLVM, TH_CMARK and TH_SWIFT (its build dirs under $SWIFT_WORK),
# TH_CHECKOUT (its own swift compiler checkout there, so neither host's patches land in the other's),
# TH_PRODUCT (its prefix under /usr/local/mavergreen and its pkg's short name) and TH_PAYLOAD (its
# payload root under $SWIFT_BUILD/payload). x86_64 is the native toolchain, which runs on OS X 10.9;
# arm64 the cross toolchain, which runs on an Apple-silicon Mac. Any other host returns 2, naming both.
toolchain_host_select() {
  case "$1" in
    x86_64) TH_LLVM=llvm-x86; TH_CMARK=cmark-x86; TH_SWIFT=swift-x86; TH_CHECKOUT=swift-compiler
            TH_PRODUCT=swift-toolchain; TH_PAYLOAD=toolchain ;;
    arm64)  TH_LLVM=llvm-arm64; TH_CMARK=cmark-arm64; TH_SWIFT=swift-arm64; TH_CHECKOUT=swift-compiler-arm64
            TH_PRODUCT=swift-toolchain-cross; TH_PAYLOAD=toolchain-cross ;;
    *) echo "the toolchain host is x86_64 (the native toolchain, for OS X 10.9) or arm64 (the cross toolchain, for an Apple-silicon Mac), not '$1'" >&2
       return 2 ;;
  esac
}

# compiler_patches x86_64|arm64 <dir> -- the patches in <dir> (patches/compiler) that host's compiler
# takes, one path per line, in order. 0002 is x86_64's alone: it gives the native swift-frontend the
# rpath @loader_path/../lib/swift/macosx, the bundled 10.9 runtime it runs on there. The cross
# package's lib/swift/macosx holds that same x86_64 stdlib, which an arm64 frontend cannot load; it
# runs on the OS's /usr/lib/swift, upstream's default without 0002. Every other patch is both hosts'.
# Returns 2 for any other host, and 1 when <dir> holds no patch for it.
compiler_patches() {
  ( toolchain_host_select "$1" ) || return 2   # validates only: the caller's TH_* stay as they were
  _cp_n=0
  for _cp_p in "$2"/*.patch; do
    [ -f "$_cp_p" ] || continue
    case "$1:${_cp_p##*/}" in arm64:0002-*) continue ;; esac
    printf '%s\n' "$_cp_p"; _cp_n=$((_cp_n + 1))
  done
  [ "$_cp_n" -gt 0 ] || { echo "compiler_patches: no $1 patches in $2" >&2; return 1; }
}

# toolchain_digest <toolchain-prefix> -- one line of `<path>=<sha256>` entries, one space apart, sorted by
# <path> (relative to the prefix), for every file under lib/swift/macosx, lib/swift/shims and
# lib/clang/<v>/lib: the stdlib's dylibs, the swiftmodules whose inlinable code lands in every program a
# toolchain builds, the shims and the builtins archive. The two toolchain pkgs must carry them byte for
# byte, and in CI two jobs build them, each from the same source with its own build.sh and
# build-builtins.sh, which is why they are compared. Fails, naming it, when an anchor (the two dylibs,
# Swift's swiftmodule, the shims' module.modulemap, the builtins archive) is missing, or a tree holds a
# link, a path with a space, or a file that cannot be hashed: two jobs that each printed nothing, or less
# than the whole trees, must never compare equal.
toolchain_digest() {
  _td_inc="$(clang_resource_include "$1")" || return 1
  _td_cl="lib/clang/$(basename "$(dirname "$_td_inc")")/lib"
  for _td_f in lib/swift/macosx/libswiftCore.dylib lib/swift/macosx/libswiftSwiftOnoneSupport.dylib \
               lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule lib/swift/shims/module.modulemap \
               "$_td_cl/darwin/libclang_rt.osx.a"; do
    [ -f "$1/$_td_f" ] || { echo "toolchain_digest: no $1/$_td_f" >&2; return 1; }
  done
  _td_list="$(cd "$1" && find $(toolchain_stdlib_trees "$_td_cl") ! -type d)" \
    || { echo "toolchain_digest: could not list $1's stdlib, shims and builtins" >&2; return 1; }
  _td_list="$(printf '%s\n' "$_td_list" | LC_ALL=C sort)"
  _td_line=""
  while IFS= read -r _td_f; do
    case "$_td_f" in *[[:space:]]*) echo "toolchain_digest: '$1/$_td_f' holds a space" >&2; return 1 ;; esac
    if [ -L "$1/$_td_f" ] || [ ! -f "$1/$_td_f" ]; then
      echo "toolchain_digest: $1/$_td_f is not a plain file" >&2; return 1
    fi
    _td_s="$(shasum -a 256 < "$1/$_td_f" | awk '{ print $1 }')"
    [ "${#_td_s}" -eq 64 ] || { echo "toolchain_digest: could not hash $1/$_td_f" >&2; return 1; }
    _td_line="$_td_line${_td_line:+ }$_td_f=$_td_s"
  done <<EOF
$_td_list
EOF
  printf '%s\n' "$_td_line"
}

# toolchain_digest_whole <line> -- 0 when <line> is a whole toolchain_digest line: `lib/<path>=<sha256>`
# entries one space apart, holding each anchor; otherwise 1, saying why.
toolchain_digest_whole() {
  [ -n "$1" ] || { echo "toolchain_digest: the line is empty" >&2; return 1; }
  case "$1" in
    ' '*|*' '|*'  '*) echo "toolchain_digest: the line holds an empty entry" >&2; return 1 ;;
  esac
  _tw_core=""; _tw_onone=""; _tw_mod=""; _tw_map=""; _tw_rt=""
  while IFS= read -r _tw_e; do
    _tw_h="${_tw_e#*=}"
    case "$_tw_e" in lib/?*=*) _tw_ok=1 ;; *) _tw_ok="" ;; esac
    case "$_tw_h" in *[!0-9a-f]*) _tw_ok="" ;; esac
    [ "${#_tw_h}" -eq 64 ] || _tw_ok=""
    [ -n "$_tw_ok" ] || { echo "toolchain_digest: '$_tw_e' is not a lib/<path>=<sha256> entry" >&2; return 1; }
    case "${_tw_e%%=*}" in
      lib/swift/macosx/libswiftCore.dylib) _tw_core=1 ;;
      lib/swift/macosx/libswiftSwiftOnoneSupport.dylib) _tw_onone=1 ;;
      lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule) _tw_mod=1 ;;
      lib/swift/shims/module.modulemap) _tw_map=1 ;;
      lib/clang/*/lib/darwin/libclang_rt.osx.a) _tw_rt=1 ;;
    esac
  done <<EOF
$(printf '%s\n' "$1" | tr ' ' '\n')
EOF
  _tw_miss=""
  [ -n "$_tw_core" ] || _tw_miss="$_tw_miss lib/swift/macosx/libswiftCore.dylib"
  [ -n "$_tw_onone" ] || _tw_miss="$_tw_miss lib/swift/macosx/libswiftSwiftOnoneSupport.dylib"
  [ -n "$_tw_mod" ] || _tw_miss="$_tw_miss lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule"
  [ -n "$_tw_map" ] || _tw_miss="$_tw_miss lib/swift/shims/module.modulemap"
  [ -n "$_tw_rt" ] || _tw_miss="$_tw_miss lib/clang/<v>/lib/darwin/libclang_rt.osx.a"
  [ -z "$_tw_miss" ] || { echo "toolchain_digest: the line has no entry for:$_tw_miss" >&2; return 1; }
}

# toolchain_digests_agree <digest> <digest> -- 0 when two toolchain_digest lines are the same whole line;
# otherwise 1, saying why, and listing the entries that differ (`<` only in the first, `>` only in the
# second). An empty or partial line never agrees, not even with itself.
toolchain_digests_agree() {
  toolchain_digest_whole "$1" || { echo "toolchain_digests_agree: the first line is not a whole toolchain_digest line" >&2; return 1; }
  toolchain_digest_whole "$2" || { echo "toolchain_digests_agree: the second line is not a whole toolchain_digest line" >&2; return 1; }
  [ "$1" != "$2" ] || return 0
  echo "toolchain_digests_agree: they differ:" >&2
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, " "); for (i = 1; i <= n; i++) inA[x[i]] = 1
    m = split(b, y, " "); for (i = 1; i <= m; i++) inB[y[i]] = 1
    for (i = 1; i <= n; i++) if (!(x[i] in inB)) print "  < " x[i]
    for (i = 1; i <= m; i++) if (!(y[i] in inA)) print "  > " y[i]
  }' >&2
  return 1
}

# clang22_prefix cross|native <repo> -- prints the prefix of the mavericks-clang-22 that compiles the
# 10.9-hosted toolchain and compiler-rt's builtins in that mode: cross, the CROSS toolchain
# <repo>/fetch-clang22.sh pins (pins.env's CLANG22_VERSION); native, the installed native one,
# ${CLANG22_PREFIX:-/usr/local/mavergreen/clang22}. Fails, naming it, when one of the tools both modes
# take from it is not there: clang, clang++ and ld64.lld, and llvm-ar, llvm-ranlib, llvm-libtool-darwin,
# llvm-lipo and llvm-nm -- one archiver, one indexer and one reader on both hosts, so the archives the
# build makes, and what links them, are the same bytes on both (T4 spike Q1 and Q5).
clang22_prefix() {
  case "$1" in
    cross) _cp="$(sh "$2/fetch-clang22.sh")" || { echo "clang22_prefix: $2/fetch-clang22.sh failed" >&2; return 1; } ;;
    native) _cp="${CLANG22_PREFIX:-/usr/local/mavergreen/clang22}" ;;
    *) echo "clang22_prefix: the mode is cross or native, not '$1'" >&2; return 2 ;;
  esac
  for _ct in clang clang++ ld64.lld llvm-ar llvm-ranlib llvm-libtool-darwin llvm-lipo llvm-nm; do
    [ -x "$_cp/bin/$_ct" ] || { echo "clang22_prefix: no $_cp/bin/$_ct (mavericks-clang-22's $1 package provides it)" >&2; return 1; }
  done
  printf '%s\n' "$_cp"
}

# sdk109_stubs -- prints the pinned MacOSX10.9.sdk exactly as its tarball holds it, its libraries the
# original MH_DYLIB_STUB files, fetched and verified with shipyard's own pin (sdk-pins.sh) and fetcher
# (mavericks_fetch.sh) into the stubs/ dir of fetch_sdk.sh's cache (MAVERICKS_SDK_CACHE). fetch_sdk.sh
# converts those stubs to .tbd wherever tapi exists, which is every modern Mac and never OS X 10.9, and lld
# orders a .tbd's exports by name but a stub's in trie order, so a toolchain linked on each differed in
# its symbol table (T4 spike Q5; shipyard BACKLOG #30): both hosts link the toolchain against these. The
# tarball fetch_sdk.sh already cached is reused. Needs $SHIPYARD (msc.sh).
sdk109_stubs() {
  _ss_cache="${MAVERICKS_SDK_CACHE:-$HOME/Library/Caches/mavericks-sdk}"
  { . "$SHIPYARD/mavericks_fetch.sh" && . "$SHIPYARD/sdk-pins.sh"; } || {
    echo "sdk109_stubs: cannot source mavericks_fetch.sh and sdk-pins.sh from $SHIPYARD" >&2; return 1; }
  _ss_pin="$(mav_sdk_pin x86_64)" || { echo "sdk109_stubs: shipyard pins no x86_64 SDK" >&2; return 1; }
  # shellcheck disable=SC2086  # the pin is four space-free words by construction (sdk-pins.sh)
  set -- $_ss_pin
  _ss_dir="$_ss_cache/stubs"
  if [ ! -d "$_ss_dir/$4/usr/lib" ]; then
    mkdir -p "$_ss_dir" || return 1
    if [ ! -f "$_ss_dir/$3" ] && [ -f "$_ss_cache/$3" ]; then cp "$_ss_cache/$3" "$_ss_dir/$3" || return 1; fi
    mav_fetch_pinned "$1" "$2" "$_ss_dir" "$3" || { echo "sdk109_stubs: could not fetch and verify $3" >&2; return 1; }
  fi
  [ -d "$_ss_dir/$4/usr/lib" ] || { echo "sdk109_stubs: $_ss_dir/$4 has no usr/lib" >&2; return 1; }
  printf '%s\n' "$_ss_dir/$4"
}

# macho_version <macho> -- `<minOS> <SDK>` as <macho> records them: dyld_info when $DYLDINFO names it;
# else otool's LC_VERSION_MIN_MACOSX or LC_BUILD_VERSION (OS X 10.9 has no dyld_info). Prints nothing
# when the file records neither; fails when the reader fails. The one parser: macho_minos is its first word.
macho_version() {
  if [ -n "${DYLDINFO:-}" ]; then
    _mv="$("$DYLDINFO" -platform "$1")" || return 1
    printf '%s\n' "$_mv" | awk '$1 == "macOS" { print $2, $3; exit }'
  else
    _mv="$(otool -l "$1")" || return 1
    printf '%s\n' "$_mv" | awk '$1 == "cmd" { c = $2 }
      c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { v = $2 }
      c == "LC_VERSION_MIN_MACOSX" && $1 == "sdk" { print v, $2; exit }
      c == "LC_BUILD_VERSION" && $1 == "minos" { v = $2 }
      c == "LC_BUILD_VERSION" && $1 == "sdk" { print v, $2; exit }'
  fi
}

# macho_rpaths <macho> -- each LC_RPATH <macho> records, one per line, in order: dyld_info when $DYLDINFO
# names it, else otool. Fails when the reader fails.
macho_rpaths() {
  if [ -n "${DYLDINFO:-}" ]; then
    _mr="$("$DYLDINFO" -rpaths "$1")" || return 1
    printf '%s\n' "$_mr" | awk 'NR > 2 { print $1 }'
  else
    _mr="$(otool -l "$1")" || return 1
    printf '%s\n' "$_mr" | awk '$1 == "cmd" { c = $2 } c == "LC_RPATH" && $1 == "path" { print $2 }'
  fi
}

# host_swiftc_stamp <toolchain-prefix> -- four lines: `prefix <toolchain-prefix>` (CMake knows the host
# swiftc by its path), then `<role> <sha256>` for what a toolchain built with that host swiftc compiles
# its Swift half with and against: the host's swift-frontend, and the Swift.swiftmodule and
# libswiftCore.dylib in its lib/swift/macosx (the stdlib's inlinable code lands in the Swift half, and
# HOSTTOOLS links against that dylib). Fails, naming it, when one is missing.
host_swiftc_stamp() {
  printf 'prefix %s\n' "$1"
  for _hw_r in swift-frontend:bin/swift-frontend \
               swiftmodule:lib/swift/macosx/Swift.swiftmodule/x86_64-apple-macos.swiftmodule \
               libswiftCore:lib/swift/macosx/libswiftCore.dylib; do
    _hw_f="$1/${_hw_r#*:}"
    [ -f "$_hw_f" ] || { echo "host_swiftc_stamp: no $_hw_f -- is a Swift toolchain at $1?" >&2; return 1; }
    _hw_s="$(shasum -a 256 < "$_hw_f" | awk '{ print $1 }')"
    [ "${#_hw_s}" -eq 64 ] || { echo "host_swiftc_stamp: could not hash $_hw_f" >&2; return 1; }
    printf '%s %s\n' "${_hw_r%%:*}" "$_hw_s"
  done
}

# swift_half_reset <swift-build-dir> <stamp> -- leaves a configured <dir> as it is when its
# mavergreen-host.stamp holds exactly <stamp> (host_swiftc_stamp's); otherwise removes CMake's cache
# (CMakeCache.txt and CMakeFiles/) and the Swift half's objects (SwiftCompilerSources/*.o), saying so,
# and keeps the rest: the C++ half does not depend on the host swiftc. CMake, seeing CMAKE_Swift_COMPILER
# change to another path, drops its cache itself and reconfigures WITHOUT the command line's -D options
# (T4 spike blocker 2), and ninja sees a compiler only by its path, which a toolchain updated in place
# keeps. An empty <stamp> is refused: it would equal the empty read of a missing stamp. The caller writes
# <stamp> there once it has configured <dir>.
swift_half_reset() {
  [ -n "$2" ] || { echo "swift_half_reset: an empty stamp for $1" >&2; return 1; }
  [ -f "$1/CMakeCache.txt" ] || return 0
  if [ "$(cat "$1/mavergreen-host.stamp" 2>/dev/null)" = "$2" ]; then return 0; fi
  echo "    $1: its host swiftc changed, or went unrecorded: configuring it afresh, and recompiling the Swift half"
  rm -rf "$1/CMakeCache.txt" "$1/CMakeFiles" "$1/mavergreen-host.stamp" && rm -f "$1"/SwiftCompilerSources/*.o
}

# stdlib_layout <lib/swift dir> -- `build` when <dir> is a stdlib build's lib/swift (build.sh's
# stdlib-build: the two dylibs in macosx/x86_64/), `toolchain` when it is a staged toolchain's (the two
# dylibs in macosx/); both hold macosx/Swift.swiftmodule, macosx/SwiftOnoneSupport.swiftmodule,
# macosx/layouts-x86_64.yaml and shims/. Fails, naming what is missing, for anything else.
stdlib_layout() {
  for _sl_f in macosx/Swift.swiftmodule macosx/SwiftOnoneSupport.swiftmodule macosx/layouts-x86_64.yaml shims; do
    [ -e "$1/$_sl_f" ] || { echo "stdlib_layout: $1 has no $_sl_f" >&2; return 1; }
  done
  if [ -f "$1/macosx/x86_64/libswiftCore.dylib" ] && [ -f "$1/macosx/x86_64/libswiftSwiftOnoneSupport.dylib" ]; then
    echo build
  elif [ -f "$1/macosx/libswiftCore.dylib" ] && [ -f "$1/macosx/libswiftSwiftOnoneSupport.dylib" ]; then
    echo toolchain
  else
    echo "stdlib_layout: $1 holds libswiftCore.dylib and libswiftSwiftOnoneSupport.dylib in neither macosx/x86_64/ (a stdlib build) nor macosx/ (a toolchain)" >&2
    return 1
  fi
}

# toolchain_stdlib_trees [<clang-lib-dir>...] -- the trees, relative to a toolchain prefix, that a
# toolchain's build makes alike wherever it runs and that two toolchain pkgs must carry byte for byte, one
# per line: lib/swift/macosx and lib/swift/shims (the stdlib), then each <clang-lib-dir> given (the
# builtins archive's lib/clang/<v>/lib, which the caller names: toolchain_digest the one its resource dir
# is, toolchain_release_files every one there is). One definition for both, so what is digested and what
# is compared cannot drift apart.
toolchain_stdlib_trees() {
  printf '%s\n' lib/swift/macosx lib/swift/shims
  for _ts_c in "$@"; do printf '%s\n' "$_ts_c"; done
}

# toolchain_release_files <toolchain-prefix> -- the files of a Swift toolchain prefix that its build makes,
# one relative path per line, sorted: bin/swift-frontend, bin/clang and bin/ld64.lld, and every file under
# toolchain_stdlib_trees (the stdlib, and the builtins archive) and share/swift (the helpers' outputs). The
# rest of a prefix (the wrappers, the docs, shipyard's SDK fetcher, clang's headers) is copied from a
# checkout or the installed shipyard.
toolchain_release_files() {
  ( cd "$1" || exit 1
    for _rf in bin/swift-frontend bin/clang bin/ld64.lld; do if [ -f "$_rf" ]; then echo "$_rf"; fi; done
    # shellcheck disable=SC2046  # trees hold no space: the glob's matches are lib/clang/<version>/lib
    for _rd in $(toolchain_stdlib_trees lib/clang/*/lib) share/swift; do
      if [ -d "$_rd" ]; then find "$_rd" -type f; fi
    done ) | LC_ALL=C sort
}

# toolchain_cmp <prefix> <prefix> -- 0 when two Swift toolchain prefixes hold the same
# toolchain_release_files, byte for byte (cmp), and prints `same: <n> files`; otherwise 1, listing each
# file that differs (`differ: <path>`) or that only one prefix holds (`only in <prefix>: <path>`). Fails
# too, saying so, when either prefix has no bin/swift-frontend: two empty lists must never compare equal.
toolchain_cmp() {
  for _tc_p in "$1" "$2"; do
    [ -f "$_tc_p/bin/swift-frontend" ] || { echo "toolchain_cmp: $_tc_p has no bin/swift-frontend" >&2; return 1; }
  done
  _tc_all="$( { toolchain_release_files "$1"; toolchain_release_files "$2"; } | LC_ALL=C sort -u)"
  _tc_rc=0; _tc_n=0
  while IFS= read -r _tc_f; do
    if [ ! -f "$1/$_tc_f" ]; then echo "only in $2: $_tc_f"; _tc_rc=1
    elif [ ! -f "$2/$_tc_f" ]; then echo "only in $1: $_tc_f"; _tc_rc=1
    elif cmp -s "$1/$_tc_f" "$2/$_tc_f"; then _tc_n=$((_tc_n + 1))
    else echo "differ: $_tc_f"; _tc_rc=1
    fi
  done <<TCEOF
$_tc_all
TCEOF
  if [ "$_tc_rc" -eq 0 ]; then echo "same: $_tc_n files"; fi
  return "$_tc_rc"
}

# pkg_extract_product <pkg> <product> <dir> -- extracts, into <dir> (replaced), the payload of the one
# component of the product archive <pkg> that installs /usr/local/mavergreen/<product>, and prints that
# prefix, <dir>/usr/local/mavergreen/<product>; the rest of the payload (an updater under Library/, the
# family's base component) is left out. pkgutil --expand and ditto, so it runs on a modern Mac and on OS X
# 10.9 alike (10.9's pkgutil has no --expand-full). Fails when no component installs that prefix, or more
# than one does. <dir> is rm -rf'd first, so it is refused when relative, when it is $HOME, and when
# scripts/outdir.sh's refuse_root_outdir (which the caller has sourced) refuses it: / by any name.
pkg_extract_product() {
  case "$3" in /*) ;; *) echo "pkg_extract_product: '$3' is not an absolute path" >&2; return 1 ;; esac
  command -v refuse_root_outdir > /dev/null 2>&1 \
    || { echo "pkg_extract_product: source scripts/outdir.sh first (refuse_root_outdir guards the rm -rf of $3)" >&2; return 1; }
  ( refuse_root_outdir pkg_extract_product "$3" ) || return 1
  if [ -d "$3" ] && [ "$(CDPATH='' cd -P -- "$3" && pwd -P)" = "$(CDPATH='' cd -P -- "$HOME" && pwd -P)" ]; then
    echo "pkg_extract_product: refusing out-dir '$3' (it is \$HOME)" >&2; return 1
  fi
  [ -f "$1" ] || { echo "pkg_extract_product: no $1" >&2; return 1; }
  rm -rf "$3" "$3.x" && mkdir -p "$3/usr/local/mavergreen" "$3.x" || return 1
  pkgutil --expand "$1" "$3.x/pkg" || { echo "pkg_extract_product: pkgutil could not expand $1" >&2; return 1; }
  _pe_n=0; _pe_hit=""
  for _pe_p in "$3.x"/pkg/*/Payload "$3.x"/pkg/Payload; do
    [ -f "$_pe_p" ] || continue
    _pe_n=$((_pe_n + 1)); _pe_t="$3.x/c$_pe_n"
    mkdir -p "$_pe_t" && ditto -x -z "$_pe_p" "$_pe_t" || { echo "pkg_extract_product: could not extract $_pe_p" >&2; return 1; }
    if [ -d "$_pe_t/usr/local/mavergreen/$2" ]; then
      [ -z "$_pe_hit" ] || { echo "pkg_extract_product: more than one component of $1 installs /usr/local/mavergreen/$2" >&2; return 1; }
      _pe_hit="$_pe_t"
    fi
  done
  [ -n "$_pe_hit" ] || { echo "pkg_extract_product: no component of $1 installs /usr/local/mavergreen/$2" >&2; return 1; }
  mv "$_pe_hit/usr/local/mavergreen/$2" "$3/usr/local/mavergreen/$2" && rm -rf "$3.x" || return 1
  printf '%s\n' "$3/usr/local/mavergreen/$2"
}
