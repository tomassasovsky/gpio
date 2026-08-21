import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

/// Direct bindings to the libc calls the GPIO character device needs.
///
/// Everything is resolved out of the running process — libc is always already
/// loaded on Linux, so there is no library to locate, package or ship.
class Libc {
  Libc._(this._lib);

  /// Resolves against the already-loaded process image.
  factory Libc.process() => Libc._(ffi.DynamicLibrary.process());

  final ffi.DynamicLibrary _lib;

  /// `open(2)`. Returns a file descriptor, or `-1` with [errno] set.
  late final int Function(ffi.Pointer<Utf8>, int) open = _lib.lookupFunction<
      ffi.Int Function(ffi.Pointer<Utf8>, ffi.Int),
      int Function(ffi.Pointer<Utf8>, int)>('open');

  /// `close(2)`.
  late final int Function(int) close =
      _lib.lookupFunction<ffi.Int Function(ffi.Int), int Function(int)>(
    'close',
  );

  /// `ioctl(2)`, with a pointer argument.
  ///
  /// libc declares this variadic, but every Linux ABI Dart targets passes that
  /// third argument in an ordinary register slot, so binding it as a fixed
  /// three-argument function is correct — and is what bindings in every other
  /// language do.
  late final int Function(int, int, ffi.Pointer<ffi.Void>) ioctl =
      _lib.lookupFunction<
          ffi.Int Function(ffi.Int, ffi.UnsignedLong, ffi.Pointer<ffi.Void>),
          int Function(int, int, ffi.Pointer<ffi.Void>)>('ioctl');

  /// `read(2)`. Returns bytes read, or `-1` with [errno] set.
  late final int Function(int, ffi.Pointer<ffi.Void>, int) read =
      _lib.lookupFunction<
          ffi.IntPtr Function(ffi.Int, ffi.Pointer<ffi.Void>, ffi.IntPtr),
          int Function(int, ffi.Pointer<ffi.Void>, int)>('read');

  /// `poll(2)`. Returns the number of ready descriptors, `0` on timeout, or
  /// `-1` with [errno] set.
  ///
  /// Used in preference to `epoll` deliberately: `struct epoll_event` is
  /// `__attribute__((packed))` **only** on x86-64 (12 bytes there, 16 on arm64
  /// and armv7), and Dart's `@Packed` annotation cannot be applied per
  /// architecture. `struct pollfd` is 8 bytes with identical offsets on every
  /// Linux ABI. With two descriptors to watch, `epoll`'s scaling advantage buys
  /// nothing, and the portable struct is worth a great deal.
  late final int Function(ffi.Pointer<PollFd>, int, int) poll =
      _lib.lookupFunction<
          ffi.Int Function(ffi.Pointer<PollFd>, ffi.UnsignedLong, ffi.Int),
          int Function(ffi.Pointer<PollFd>, int, int)>('poll');

  /// `eventfd(2)`. A descriptor whose only job is to break a blocking [poll].
  late final int Function(int, int) eventfd = _lib.lookupFunction<
      ffi.Int Function(ffi.UnsignedInt, ffi.Int),
      int Function(int, int)>('eventfd');

  /// `write(2)`.
  late final int Function(int, ffi.Pointer<ffi.Void>, int) write =
      _lib.lookupFunction<
          ffi.IntPtr Function(ffi.Int, ffi.Pointer<ffi.Void>, ffi.IntPtr),
          int Function(int, ffi.Pointer<ffi.Void>, int)>('write');

  late final ffi.Pointer<ffi.Int> Function() _errnoLocation = _lookupErrno();

  /// glibc and musl export `__errno_location`; Android's bionic exports
  /// `__errno`. Resolving lazily *and* only on a failure path would mean the
  /// first real error on bionic surfaced as "Failed to lookup symbol" instead
  /// of the errno it was trying to report -- the worst possible moment to lose
  /// the diagnosis.
  ffi.Pointer<ffi.Int> Function() _lookupErrno() {
    for (final symbol in const ['__errno_location', '__errno']) {
      if (_lib.providesSymbol(symbol)) {
        return _lib.lookupFunction<ffi.Pointer<ffi.Int> Function(),
            ffi.Pointer<ffi.Int> Function()>(symbol);
      }
    }
    throw UnsupportedError(
      'No errno accessor found in this process: tried __errno_location '
      '(glibc, musl) and __errno (bionic).',
    );
  }

  /// The calling thread's `errno`.
  ///
  /// Synchronous FFI calls run on the calling isolate's own thread, so reading
  /// this immediately after a failed call sees that call's value — there is no
  /// thread hop in between.
  int get errno => _errnoLocation().value;
}

/// `struct pollfd`.
///
/// 8 bytes on every Linux ABI, unlike `struct epoll_event`.
final class PollFd extends ffi.Struct {
  /// The descriptor to watch.
  @ffi.Int()
  external int fd;

  /// Requested events.
  @ffi.Short()
  external int events;

  /// Events that occurred.
  @ffi.Short()
  external int revents;
}

/// `poll(2)` event bits.
class PollEvents {
  const PollEvents._();

  /// Data is available to read.
  static const int pollIn = 0x001;

  /// An error occurred.
  static const int pollErr = 0x008;

  /// The descriptor hung up — the device went away.
  static const int pollHup = 0x010;

  /// The descriptor is not open.
  static const int pollNval = 0x020;
}

/// The `open(2)` flags this package uses.
class OpenFlags {
  const OpenFlags._();

  /// `O_RDONLY`.
  static const int readOnly = 0x0;

  /// `O_RDWR`.
  static const int readWrite = 0x2;

  /// `O_CLOEXEC` — do not leak the descriptor across `exec`.
  static const int closeOnExec = 0x80000;

  /// `O_NONBLOCK`.
  static const int nonBlock = 0x800;
}

/// The `errno` values this package maps to specific, actionable messages.
class Errno {
  const Errno._();

  /// `EPERM` — operation not permitted.
  static const int eperm = 1;

  /// `ENOENT` — no such file or directory; the chip is not present.
  static const int enoent = 2;

  /// `EINTR` — interrupted by a signal; the call should be retried.
  static const int eintr = 4;

  /// `EIO` — low-level I/O error.
  static const int eio = 5;

  /// `EBADF` — the descriptor is closed or was never valid.
  static const int ebadf = 9;

  /// `EAGAIN` — nothing available right now on a non-blocking descriptor.
  static const int eagain = 11;

  /// `EACCES` — permission denied; usually the `gpio` group or a udev rule.
  static const int eacces = 13;

  /// `EBUSY` — the line is already requested by another consumer.
  static const int ebusy = 16;

  /// `ENODEV` — the device went away, e.g. an unplugged USB GPIO adapter.
  static const int enodev = 19;

  /// `EINVAL` — the kernel rejected the request as malformed.
  static const int einval = 22;

  /// `ENOTTY` — not a GPIO character device, or the ioctl is unknown to this
  /// kernel (a v2 request on a kernel older than 5.10 lands here).
  static const int enotty = 25;
}
