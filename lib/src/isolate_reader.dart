import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:gpio/src/ffi/libc.dart';

/// Blocks on `poll(2)` for fixed-size kernel records and hands each one over.
///
/// Shared by the edge-event reader and the line-info watcher, which differ only
/// in which descriptor they watch and what shape of record comes out of it. The
/// loop itself — the `EINTR` retry, the shutdown descriptor winning over a
/// pending read, the short-read guard — is identical, and is the part where the
/// bugs live, so there is exactly one copy of it.
///
/// [onRecord] is called with the buffer filled, once per whole record read. It
/// runs on the reader isolate, so it must do nothing but hand the data on.
void pollRecords({
  required Libc libc,
  required int dataFd,
  required int wakeupFd,
  required int recordSize,
  required ffi.Pointer<ffi.Void> buffer,
  required void Function() onRecord,
}) {
  final fds = calloc<PollFd>(2);
  try {
    fds[0]
      ..fd = dataFd
      ..events = PollEvents.pollIn;
    fds[1]
      ..fd = wakeupFd
      ..events = PollEvents.pollIn;

    while (true) {
      final ready = libc.poll(fds, 2, -1);
      if (ready < 0) {
        if (libc.errno == Errno.eintr) continue;
        break;
      }

      // Shutdown wins over draining: once close() has fired, the data fd is
      // about to be closed under us. Any revent on the wakeup descriptor ends
      // the loop -- not just POLLIN -- because a POLLNVAL there would otherwise
      // spin at 100% forever.
      if (fds[1].revents != 0) break;

      final revents = fds[0].revents;
      if (revents &
              (PollEvents.pollErr | PollEvents.pollHup | PollEvents.pollNval) !=
          0) {
        break;
      }
      if (revents & PollEvents.pollIn == 0) continue;

      final n = libc.read(dataFd, buffer, recordSize);
      if (n < 0) {
        if (libc.errno == Errno.eintr || libc.errno == Errno.eagain) continue;
        break;
      }
      // A short read cannot yield a usable record; the kernel only ever writes
      // whole ones, so this means the descriptor is finished.
      if (n < recordSize) break;

      onRecord();
    }
  } finally {
    calloc.free(fds);
  }
}

/// The shutdown half of an isolate-backed reader.
///
/// Owns the `eventfd` that breaks the blocking `poll`, the receive port, and
/// the "isolate has actually left the syscall" signal. Every one of those three
/// exists because of a teardown race that was observed and fixed: a reader that
/// spun on `POLLNVAL`, a descriptor closed while an isolate was still reading
/// from it, and a controller that never completed its `close()`.
///
/// Composed rather than inherited so both readers get the identical, tested
/// shutdown path without either owning it.
class IsolateReaderCore {
  /// Creates a core over a live isolate.
  IsolateReaderCore({
    required Libc libc,
    required int wakeupFd,
    required ReceivePort receivePort,
    required Future<void> exited,
  })  : _libc = libc,
        _wakeupFd = wakeupFd,
        _receivePort = receivePort,
        _exited = exited,
        _onClose = null;

  /// Creates a core with no isolate behind it, for fakes and tests.
  IsolateReaderCore.forTesting({required Future<void> Function() onClose})
      : _libc = null,
        _wakeupFd = -1,
        _receivePort = null,
        _exited = null,
        _onClose = onClose;

  final Libc? _libc;
  final int _wakeupFd;
  final ReceivePort? _receivePort;
  final Future<void>? _exited;
  final Future<void> Function()? _onClose;
  var _closed = false;

  /// Whether [close] has already run.
  bool get isClosed => _closed;

  /// Stops the isolate and releases the wakeup descriptor. Idempotent.
  ///
  /// Immediate: writing to the eventfd breaks the blocking `poll` rather than
  /// leaving the isolate to notice on some later timeout. An appliance that
  /// idles therefore actually idles.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    final onClose = _onClose;
    if (onClose != null) {
      await onClose();
      return;
    }

    final libc = _libc!;
    final one = calloc<ffi.Uint64>()..value = 1;
    try {
      libc.write(_wakeupFd, one.cast(), 8);
    } finally {
      calloc.free(one);
    }
    // Wait for the isolate to actually leave its poll/read before anyone closes
    // the data descriptor: a descriptor number is reused the moment it is free,
    // so a straggling read could land on an unrelated file. The timeout is a
    // backstop against a wedged isolate, not the expected path.
    await _exited?.timeout(const Duration(seconds: 2), onTimeout: () {});
    _receivePort!.close();
    libc.close(_wakeupFd);
  }
}

/// Wires a [ReceivePort] into a broadcast stream that ends on the isolate's
/// `null` sentinel, and a future that completes when it does.
///
/// The isolate sends `null` as its last act, which both ends the stream and
/// tells [IsolateReaderCore.close] that nothing is touching the data
/// descriptor any more.
({Stream<T> stream, Future<void> exited}) wireIsolatePort<T>(
  ReceivePort port,
) {
  final exited = Completer<void>();
  final stream = port.takeWhile((m) => m != null).cast<T>();
  final broadcast = stream.asBroadcastStream()
    ..listen(
      null,
      onDone: () {
        if (!exited.isCompleted) exited.complete();
      },
    );
  return (stream: broadcast, exited: exited.future);
}
