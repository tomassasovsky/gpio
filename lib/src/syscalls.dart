import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:gpio/src/event_isolate.dart';
import 'package:gpio/src/ffi/libc.dart';
import 'package:meta/meta.dart';

/// The single seam between this package and the kernel.
///
/// Every syscall the package makes goes through here, which is what lets the
/// entire GPIO layer above be tested against an in-memory fake kernel — on any
/// machine, including one with no GPIO controller and no Linux at all. The real
/// implementation ([LibcSyscalls]) is a thin pass-through; it holds no logic
/// worth testing, so nothing of substance is left uncovered by that swap.
abstract interface class Syscalls {
  /// `open(2)`. Returns a file descriptor, or `-1` with [errno] set.
  int open(String path, int flags);

  /// `close(2)`.
  int close(int fd);

  /// `ioctl(2)` with a pointer argument.
  int ioctl(int fd, int request, ffi.Pointer<ffi.Void> argp);

  /// `read(2)`. Returns bytes read, or `-1` with [errno] set.
  int read(int fd, ffi.Pointer<ffi.Void> buf, int count);

  /// The calling thread's `errno`, valid immediately after a failed call.
  int get errno;

  /// Opens a stream of raw edge events for a line-request descriptor.
  ///
  /// Behind the seam like every other syscall, so a test can supply events
  /// without a kernel, a chip, or a spawned isolate.
  Future<GpioEventReader> openEvents(int fd);

  /// Lists the GPIO character devices present, as absolute paths.
  ///
  /// Sits here rather than in the chip layer because it is the one piece of
  /// discovery that touches the filesystem, and a fake kernel needs to answer
  /// it to be useful.
  List<String> listGpioChipPaths();
}

/// [Syscalls] backed by the real libc.
class LibcSyscalls implements Syscalls {
  /// Binds to the process's libc, or to [libc] when one is supplied.
  LibcSyscalls([Libc? libc]) : _libc = libc ?? Libc.process();

  final Libc _libc;

  @override
  int open(String path, int flags) {
    final native = path.toNativeUtf8();
    final int fd;
    final int err;
    try {
      fd = _libc.open(native, flags);
      // Latch errno BEFORE freeing. `free` is not guaranteed errno-safe on
      // every libc, and it can issue syscalls of its own (madvise, munmap) --
      // so a `finally { free }` between the failed call and the caller's read
      // can turn an EACCES into something unrelated and baffling.
      err = fd < 0 ? _libc.errno : 0;
    } finally {
      calloc.free(native);
    }
    _lastOpenErrno = err;
    return fd;
  }

  /// `errno` from the most recent [open], latched before its buffer was freed.
  int _lastOpenErrno = 0;

  @override
  int close(int fd) => _libc.close(fd);

  @override
  int ioctl(int fd, int request, ffi.Pointer<ffi.Void> argp) =>
      _libc.ioctl(fd, request, argp);

  @override
  int read(int fd, ffi.Pointer<ffi.Void> buf, int count) =>
      _libc.read(fd, buf, count);

  @override
  int get errno => _lastOpenErrno != 0 ? _lastOpenErrno : _libc.errno;

  @override
  Future<GpioEventReader> openEvents(int fd) =>
      GpioEventReader.start(fd, libc: _libc);

  @override
  List<String> listGpioChipPaths() {
    const dev = '/dev';
    final dir = Directory(dev);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync(followLinks: false)
        .map((e) => e.path)
        .where((p) => _chipName.hasMatch(p.split('/').last))
        .toList()
      ..sort(_byChipIndex);
  }

  /// `gpiochip0`, `gpiochip12` — but not `gpiochip` or `gpiochipfoo`.
  static final _chipName = RegExp(r'^gpiochip(\d+)$');

  /// Numeric order, so `gpiochip2` sorts before `gpiochip10`.
  static int _byChipIndex(String a, String b) {
    final ai = int.parse(_chipName.firstMatch(a.split('/').last)!.group(1)!);
    final bi = int.parse(_chipName.firstMatch(b.split('/').last)!.group(1)!);
    return ai.compareTo(bi);
  }
}

/// Marks the seam as the intended extension point for tests.
@visibleForTesting
typedef SyscallsFactory = Syscalls Function();
