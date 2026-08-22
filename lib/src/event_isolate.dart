import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/libc.dart';
import 'package:gpio/src/isolate_reader.dart';

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
  final buffer = calloc<gpio_v2_line_event>();
  try {
    pollRecords(
      libc: libc,
      dataFd: args.requestFd,
      wakeupFd: args.wakeupFd,
      recordSize: ffi.sizeOf<gpio_v2_line_event>(),
      buffer: buffer.cast(),
      onRecord: () => args.port.send(
        (
          offset: buffer.ref.offset,
          id: buffer.ref.id,
          timestampNanos: buffer.ref.timestamp_ns,
          seqno: buffer.ref.seqno,
          lineSeqno: buffer.ref.line_seqno,
        ),
      ),
    );
  } finally {
    calloc.free(buffer);
    args.port.send(null); // "no more events" — closes the stream cleanly.
  }
}

/// Owns the event isolate and the eventfd used to stop it.
class GpioEventReader {
  GpioEventReader._(this._core, this.events);

  /// Builds a reader over an arbitrary stream, for fakes and tests.
  ///
  /// Exists so `FakeKernel` can satisfy the same seam without spawning an
  /// isolate — the code under test cannot tell the difference.
  GpioEventReader.forTesting({
    required this.events,
    required Future<void> Function() onClose,
  }) : _core = IsolateReaderCore.forTesting(onClose: onClose);

  /// Starts reading events from [requestFd].
  static Future<GpioEventReader> start(int requestFd, {Libc? libc}) async {
    final c = libc ?? Libc.process();
    final wakeupFd = c.eventfd(0, 0);
    if (wakeupFd < 0) {
      throw StateError('eventfd failed with errno ${c.errno}');
    }
    final port = ReceivePort();
    final wired = wireIsolatePort<RawLineEvent>(port);

    try {
      await Isolate.spawn(
        eventIsolateMain,
        (port: port.sendPort, requestFd: requestFd, wakeupFd: wakeupFd),
        debugName: 'gpio-events-$requestFd',
      );
    } on Object {
      // Neither the descriptor nor the port may outlive a failed spawn.
      port.close();
      c.close(wakeupFd);
      rethrow;
    }
    return GpioEventReader._(
      IsolateReaderCore(
        libc: c,
        wakeupFd: wakeupFd,
        receivePort: port,
        exited: wired.exited,
      ),
      wired.stream,
    );
  }

  final IsolateReaderCore _core;

  /// The raw events, in arrival order.
  final Stream<RawLineEvent> events;

  /// Stops the isolate and releases the wakeup descriptor.
  Future<void> close() => _core.close();
}
