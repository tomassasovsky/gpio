import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/libc.dart';
import 'package:gpio/src/ffi/names.dart';
import 'package:gpio/src/isolate_reader.dart';

/// One raw `gpio_v2_line_info_changed`, as it crosses the isolate boundary.
///
/// The `gpio_v2_line_info` payload is flattened to the fields the public
/// `GpioLineInfo` needs, because a `Struct` cannot be sent between isolates —
/// it is a view onto native memory that the reader isolate is about to reuse
/// for the next record.
typedef RawInfoEvent = ({
  int offset,
  String name,
  String consumer,
  int flags,
  int debounceMicros,
  int timestampNanos,
  int changeType,
});

/// Arguments for [infoIsolateMain], flattened for `Isolate.spawn`.
typedef InfoIsolateArgs = ({SendPort port, int chipFd, int wakeupFd});

/// Blocks on `poll(2)` for line-info changes and forwards them over a port.
///
/// Watches the **chip** descriptor, not a request: these events are the
/// kernel's report that some process — very possibly another one — requested,
/// released, or reconfigured a line.
Future<void> infoIsolateMain(InfoIsolateArgs args) async {
  final libc = Libc.process();
  final buffer = calloc<gpio_v2_line_info_changed>();
  try {
    pollRecords(
      libc: libc,
      dataFd: args.chipFd,
      wakeupFd: args.wakeupFd,
      recordSize: ffi.sizeOf<gpio_v2_line_info_changed>(),
      buffer: buffer.cast(),
      onRecord: () {
        final info = buffer.ref.info;
        var debounce = 0;
        for (var i = 0; i < info.num_attrs; i++) {
          final attr = info.attrs[i];
          if (attr.id ==
              gpio_v2_line_attr_id.GPIO_V2_LINE_ATTR_ID_DEBOUNCE.value) {
            debounce = attr.unnamed.debounce_period_us;
          }
        }
        args.port.send(
          (
            offset: info.offset,
            name: readName(info.name, GPIO_MAX_NAME_SIZE),
            consumer: readName(info.consumer, GPIO_MAX_NAME_SIZE),
            flags: info.flags,
            debounceMicros: debounce,
            timestampNanos: buffer.ref.timestamp_ns,
            changeType: buffer.ref.event_type,
          ),
        );
      },
    );
  } finally {
    calloc.free(buffer);
    args.port.send(null); // "no more events" — closes the stream cleanly.
  }
}

/// Owns the line-info isolate and the eventfd used to stop it.
class GpioInfoReader {
  GpioInfoReader._(this._core, this.events);

  /// Builds a reader over an arbitrary stream, for fakes and tests.
  GpioInfoReader.forTesting({
    required this.events,
    required Future<void> Function() onClose,
  }) : _core = IsolateReaderCore.forTesting(onClose: onClose);

  /// Starts reading line-info changes from [chipFd].
  static Future<GpioInfoReader> start(int chipFd, {Libc? libc}) async {
    final c = libc ?? Libc.process();
    final wakeupFd = c.eventfd(0, 0);
    if (wakeupFd < 0) {
      throw StateError('eventfd failed with errno ${c.errno}');
    }
    final port = ReceivePort();
    final wired = wireIsolatePort<RawInfoEvent>(port);

    try {
      await Isolate.spawn(
        infoIsolateMain,
        (port: port.sendPort, chipFd: chipFd, wakeupFd: wakeupFd),
        debugName: 'gpio-lineinfo-$chipFd',
      );
    } on Object {
      port.close();
      c.close(wakeupFd);
      rethrow;
    }
    return GpioInfoReader._(
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

  /// The raw line-info changes, in arrival order.
  final Stream<RawInfoEvent> events;

  /// Stops the isolate and releases the wakeup descriptor.
  Future<void> close() => _core.close();
}
