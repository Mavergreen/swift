// darwin_overlay_test.swift — the Darwin overlay (swift-6.2's Platform.swift and tgmath) on 10.9.
//
// `import Darwin` here is libswiftDarwin.dylib's module, not the bare Clang one: open(_:_:_:) (the C
// open is variadic, which Swift cannot call), the computed `errno` over __error(), POSIXErrorCode and
// the tgmath functions all come from the overlay. Each is exercised for real against the file system.
// Exits non-zero on any wrong answer.

import Darwin

var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failures += 1 } }

// open(_:_:_:) is the overlay's (the C open is variadic, which Swift cannot call).
let path = "/var/tmp/darwin-overlay-test-\(getpid())"
let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
check(fd >= 0, "open(O_CREAT) returned \(fd), errno \(errno)")
if fd >= 0 {
  let msg = Array("hello from 10.9\n".utf8)
  check(write(fd, msg, msg.count) == msg.count, "write")
  close(fd)
  var st = stat()
  check(stat(path, &st) == 0 && st.st_size == off_t(msg.count), "stat size")
  check(st.st_mode & 0o777 == 0o600, "mode \(String(st.st_mode & 0o777, radix: 8))")
  unlink(path)
}
// errno is the overlay's computed var over __error().
errno = 0
let bad = open("/nonexistent/a1/smoke", O_RDONLY)
check(bad == -1 && errno == ENOENT, "open(nonexistent) gave \(bad), errno \(errno)")
errno = EAGAIN
check(errno == EAGAIN, "errno is settable")
// POSIXErrorCode and the overlay's tgmath, too.
check(POSIXErrorCode(rawValue: ENOENT) == .ENOENT, "POSIXErrorCode")
check(abs(sqrt(2.0) * sqrt(2.0) - 2.0) < 1e-12, "sqrt")
check(fabs(-1.5) == 1.5, "fabs")

if failures > 0 { print("darwin_overlay_test FAILED (\(failures))"); exit(1) }
print("darwin_overlay_test OK")
exit(0)
