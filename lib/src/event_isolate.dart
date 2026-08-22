import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/libc.dart';

/// One raw `gpio_v2_line_event`, as it crosses the isolate boundary.
///
/// Deliberately a record of plain ints: cheap to send, and it keeps decoding
/// (and therefore sequence-gap detection) in the main isolate where it can be
/// tested without spawning anything.
typedef RawLineEvent = ({
  int offset,
  int id,
  int timestampNanos,
  int seqno,
  int lineSeqno,
});

/// Arguments for [eventIsolateMain], flattened for `Isolate.spawn`.
typedef EventIsolateArgs = ({SendPort port, int requestFd, int wakeupFd});

/// Blocks on `poll(2)` for GPIO edge events and forwards them over a port.
///
/// Runs on its own isolate because the read blocks: nothing else may be sharing
/// this thread. Two descriptors are watched — the request itself, and an
/// `eventfd` written to by [GpioEventReader.close] so shutdown is immediate
/// rather than waiting out a timeout.
Future<void> eventIsolateMain(EventIsolateArgs args) async {
  final libc = Libc.process();
  final fds = calloc<PollFd>(2);
  final buffer = calloc<gpio_v2_line_event>();
  final eventSize = ffi.sizeOf<gpio_v2_line_event>();

  try {
    fds[0]
      ..fd = args.requestFd
      ..events = PollEvents.pollIn;
    fds[1]
      ..fd = args.wakeupFd
      ..events = PollEvents.pollIn;

    while (true) {
      final ready = libc.poll(fds, 2, -1);
      if (ready < 0) {
        if (libc.errno == Errno.eintr) continue;
        break;
      }

      // Shutdown wins over draining: once close() has fired, the request fd is
      // about to be closed under us.
      if (fds[1].revents & PollEvents.pollIn != 0) break;

      final revents = fds[0].revents;
      if (revents &
              (PollEvents.pollErr | PollEvents.pollHup | PollEvents.pollNval) !=
          0) {
        break;
      }
      if (revents & PollEvents.pollIn == 0) continue;

      final n = libc.read(args.requestFd, buffer.cast(), eventSize);
      if (n < 0) {
        if (libc.errno == Errno.eintr || libc.errno == Errno.eagain) continue;
        break;
      }
      // A short read cannot yield a usable event; the kernel only ever writes
      // whole records, so this means the descriptor is finished.
      if (n < eventSize) break;

      args.port.send(
        (
          offset: buffer.ref.offset,
          id: buffer.ref.id,
          timestampNanos: buffer.ref.timestamp_ns,
          seqno: buffer.ref.seqno,
          lineSeqno: buffer.ref.line_seqno,
        ),
      );
    }
  } finally {
    calloc
      ..free(fds)
      ..free(buffer);
    args.port.send(null); // "no more events" — closes the stream cleanly.
  }
}

/// Owns the event isolate and the eventfd used to stop it.
class GpioEventReader {
  GpioEventReader._(this._libc, this._wakeupFd, this._receivePort, this.events);

  /// Builds a reader over an arbitrary stream, for fakes and tests.
  ///
  /// Exists so `FakeKernel` can satisfy the same seam without spawning an
  /// isolate — the code under test cannot tell the difference.
  GpioEventReader.forTesting({
    required this.events,
    required Future<void> Function() onClose,
  })  : _libc = null,
        _wakeupFd = -1,
        _receivePort = null,
        _onClose = onClose;

  /// Starts reading events from [requestFd].
  static Future<GpioEventReader> start(int requestFd, {Libc? libc}) async {
    final c = libc ?? Libc.process();
    final wakeupFd = c.eventfd(0, 0);
    if (wakeupFd < 0) {
      throw StateError('eventfd failed with errno ${c.errno}');
    }
    final port = ReceivePort();
    await Isolate.spawn(
      eventIsolateMain,
      (port: port.sendPort, requestFd: requestFd, wakeupFd: wakeupFd),
      debugName: 'gpio-events-$requestFd',
    );
    return GpioEventReader._(
      c,
      wakeupFd,
      port,
      port.takeWhile((m) => m != null).cast<RawLineEvent>(),
    );
  }

  final Libc? _libc;
  final int _wakeupFd;
  final ReceivePort? _receivePort;
  Future<void> Function()? _onClose;
  var _closed = false;

  /// The raw events, in arrival order.
  final Stream<RawLineEvent> events;

  /// Stops the isolate and releases the wakeup descriptor.
  ///
  /// Immediate: writing to the eventfd breaks the blocking `poll` rather than
  /// leaving the isolate to notice on some later timeout.
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
    _receivePort!.close();
    libc.close(_wakeupFd);
  }
}
