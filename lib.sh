#!/bin/sh
# platform: macOS-only -- runs pkgutil
# lib.sh — the build root and the swift.org installer check, shared by every build script (sourced
# after pins.env, which supplies TOOLCHAIN_SIGNER), and the helpers build.sh builds the runtime with on
# either host (the dirs it hands the compilers, the prefix maps, the preflight's Mach-O readers). One
# copy, so no two scripts disagree about where the build lives or what a trusted installer is.

# platform: a family checkout may live on NFS, where a build cost 11.16s wall / 25% CPU against
#           2.96s / 88% on local disk with identical user time -- the whole difference is I/O wait.
: "${MAVERICKS_BUILD_ROOT:=${TMPDIR:-/tmp}/mm-build}"
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

# host_inputs_stamp <swift-frontend> <clang> <builtins-archive> -- three lines, `<role> <sha256>`, for the
# host compiler, the host clang and the builtins archive a stdlib build is configured with. Their bytes
# reach the runtime, yet the build cannot see them change: nothing in the stdlib's CMake depends on an
# external SWIFT_NATIVE_SWIFT_TOOLS_PATH compiler, no C++ object on its compiler's bytes, and no link on
# the archive -resource-dir names. Fails, naming it, when one cannot be hashed.
host_inputs_stamp() {
  for _hs_r in swift-frontend:"$1" clang:"$2" builtins:"$3"; do
    _hs_f="${_hs_r#*:}"
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
  echo "    removing $1: its host compiler, clang or builtins archive changed, or went unrecorded"
  rm -rf "$1"
}

# macho_minos <macho> -- the minimum macOS <macho> records. dyld_info when $DYLDINFO names it; else
# otool's LC_VERSION_MIN_MACOSX or LC_BUILD_VERSION (OS X 10.9 has no dyld_info). Prints nothing when
# the file records neither.
macho_minos() {
  if [ -n "${DYLDINFO:-}" ]; then
    "$DYLDINFO" -platform "$1" | awk '$1 == "macOS" { print $2; exit }'
  else
    otool -l "$1" | awk '$1 == "cmd" { c = $2 }
      c == "LC_VERSION_MIN_MACOSX" && $1 == "version" { print $2; exit }
      c == "LC_BUILD_VERSION" && $1 == "minos" { print $2; exit }'
  fi
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

# toolchain_digest <toolchain-prefix> -- one line, `<name>=<sha256>` for each file both toolchain pkgs
# must carry byte for byte, because both are staged from the one stdlib build and the one builtins
# archive: lib/swift/macosx/libswiftCore.dylib, lib/swift/macosx/libswiftSwiftOnoneSupport.dylib and
# lib/clang/<v>/lib/darwin/libclang_rt.osx.a, in that order, space-separated. Fails, naming it, when a
# file is missing: two jobs that each printed nothing must never compare equal.
toolchain_digest() {
  _td_inc="$(clang_resource_include "$1")" || return 1
  _td_line=""
  for _td_f in "$1/lib/swift/macosx/libswiftCore.dylib" "$1/lib/swift/macosx/libswiftSwiftOnoneSupport.dylib" \
               "${_td_inc%/include}/lib/darwin/libclang_rt.osx.a"; do
    [ -f "$_td_f" ] || { echo "toolchain_digest: no $_td_f" >&2; return 1; }
    _td_s="$(shasum -a 256 "$_td_f" | awk '{ print $1 }')"
    [ "${#_td_s}" -eq 64 ] || { echo "toolchain_digest: could not hash $_td_f" >&2; return 1; }
    _td_line="$_td_line${_td_line:+ }${_td_f##*/}=$_td_s"
  done
  printf '%s\n' "$_td_line"
}

# toolchain_digests_agree <digest> <digest> -- 0 when two toolchain_digest lines are the same complete
# line; otherwise 1, saying why. An empty or partial line never agrees, not even with itself.
toolchain_digests_agree() {
  for _ta_d in "$1" "$2"; do
    case "$_ta_d" in
      libswiftCore.dylib=?*' 'libswiftSwiftOnoneSupport.dylib=?*' 'libclang_rt.osx.a=?*) ;;
      *) echo "toolchain_digests_agree: '$_ta_d' is not a whole toolchain_digest line" >&2; return 1 ;;
    esac
  done
  [ "$1" = "$2" ] || { echo "toolchain_digests_agree: they differ:
  $1
  $2" >&2; return 1; }
}
