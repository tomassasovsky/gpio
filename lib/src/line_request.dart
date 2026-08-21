import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:gpio/src/chip.dart';
import 'package:gpio/src/event_isolate.dart';
import 'package:gpio/src/events.dart';
import 'package:gpio/src/exception.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/ioctl.dart';
import 'package:gpio/src/line_config.dart';
import 'package:gpio/src/models.dart';
import 'package:gpio/src/request_encoder.dart';
import 'package:gpio/src/syscalls.dart';

/// A set of claimed lines.
///
/// The kernel ties line ownership to this object's descriptor, so the lines are
/// held until [close] — independently of the [GpioChip] they came from.
class LineRequest {
  /// Wraps a descriptor already returned by `GPIO_V2_GET_LINE`.
  LineRequest.fromFd({
    required Syscalls syscalls,
    required int fd,
    required List<LineConfig> lines,
    required String chipPath,
    EventClock eventClock = EventClock.monotonic,
  })  : _eventClock = eventClock,
        _syscalls = syscalls,
        _fd = fd,
        _chipPath = chipPath,
        _lines = List.unmodifiable(lines),
        _indexOf = {
          for (var i = 0; i < lines.length; i++) lines[i].offset: i,
        };

  final Syscalls _syscalls;
  final int _fd;
  final String _chipPath;
  final EventClock _eventClock;
  List<LineConfig> _lines;
  Map<int, int> _indexOf;
  var _closed = false;

  /// The line offsets held by this request, in request order.
  List<int> get offsets => [for (final l in _lines) l.offset];

  /// The descriptor the kernel gave us. Needed by the event layer.
  int get fd {
    _checkOpen();
    return _fd;
  }

  /// Whether any held line asks for edge events.
  bool get hasEdgeEvents => _lines.any((l) => l.wantsEvents);

  StreamController<LineEvent>? _events;
  GpioEventReader? _reader;

  /// Edge transitions on the held lines, as the kernel reports them.
  ///
  /// Timestamps come from the kernel, stamped in the interrupt handler, so
  /// delivery jitter never corrupts them — only when you hear about an event,
  /// not what time it says.
  ///
  /// A [LineEventsDropped] is emitted when the kernel's per-request FIFO
  /// overflowed and edges were lost. It arrives *before* the event that
  /// followed the gap, so a listener learns it missed something before seeing
  /// what came next.
  ///
  /// The stream is single-subscription: it owns an isolate, and handing the
  /// same one to two listeners would mean each seeing half the events. Cancel
  /// the subscription, or [close] the request, to stop it.
  Stream<LineEvent> get events {
    _checkOpen();
    if (!hasEdgeEvents) {
      throw StateError(
        'No line in this request asked for edge detection. Pass an `edge:` '
        'other than Edge.none to LineConfig.input, or reconfigure().',
      );
    }
    if (_events == null) _startEvents();
    return _events!.stream;
  }

  void _startEvents() {
    final decoder = EventDecoder(offsets);
    late final StreamController<LineEvent> controller;
    StreamSubscription<RawLineEvent>? subscription;

    controller = StreamController<LineEvent>(
      onListen: () async {
        try {
          final reader = await _syscalls.openEvents(_fd);
          _reader = reader;
          // The request may have been closed while the isolate was starting.
          if (_closed) {
            await reader.close();
            await controller.close();
            return;
          }
          subscription = reader.events.listen(
            (raw) => decoder
                .decode(
                  offset: raw.offset,
                  id: raw.id,
                  timestampNanos: raw.timestampNanos,
                  seqno: raw.seqno,
                  lineSeqno: raw.lineSeqno,
                )
                .forEach(controller.add),
            onDone: controller.close,
            onError: controller.addError,
          );
        } on Object catch (error, stack) {
          // The request may have been closed while openEvents was in flight,
          // which closes this controller — adding to a closed controller throws
          // a StateError with nobody to catch it.
          if (!controller.isClosed) {
            controller.addError(error, stack);
            unawaited(controller.close());
          }
        }
      },
      onCancel: () async {
        await subscription?.cancel();
        await _reader?.close();
        _reader = null;
        _events = null;
      },
    );
    _events = controller;
  }

  /// Reads every held line in one ioctl.
  ///
  /// Atomic across the request: the values come from a single sample, so a bank
  /// of switches cannot be caught mid-scan showing two different instants.
  Map<int, bool> getValues() {
    _checkOpen();
    final buf = calloc<gpio_v2_line_values>();
    try {
      buf.ref.mask = _maskOfAll();
      if (_syscalls.ioctl(_fd, GpioIoctl.v2LineGetValues, buf.cast()) < 0) {
        throw GpioException(
          'GPIO_V2_LINE_GET_VALUES',
          _syscalls.errno,
          path: _chipPath,
        );
      }
      final bits = buf.ref.bits;
      return {
        for (var i = 0; i < _lines.length; i++)
          _lines[i].offset: bits & (1 << i) != 0,
      };
    } finally {
      calloc.free(buf);
    }
  }

  /// Reads a single line.
  bool getValue(int offset) => getValues()[_requireHeld(offset)]!;

  /// Drives the given lines in one ioctl.
  ///
  /// Lines absent from [values] are left alone — the mask covers only what is
  /// named, so this cannot glitch a line you did not mention.
  void setValues(Map<int, bool> values) {
    _checkOpen();
    if (values.isEmpty) return;
    var mask = 0;
    var bits = 0;
    for (final entry in values.entries) {
      final index = _indexOf[_requireHeld(entry.key)]!;
      // Caught here rather than left to the kernel: SET_VALUES on an input
      // returns EPERM, which reads as a permissions problem and sends people
      // hunting for udev rules that are not the issue.
      if (_lines[index].direction != LineDirection.output) {
        throw ArgumentError.value(
          entry.key,
          'values',
          'line ${entry.key} was requested as an input and cannot be driven; '
              'reconfigure it as an output first',
        );
      }
      mask |= 1 << index;
      if (entry.value) bits |= 1 << index;
    }
    final buf = calloc<gpio_v2_line_values>();
    try {
      buf.ref
        ..mask = mask
        ..bits = bits;
      if (_syscalls.ioctl(_fd, GpioIoctl.v2LineSetValues, buf.cast()) < 0) {
        throw GpioException(
          'GPIO_V2_LINE_SET_VALUES',
          _syscalls.errno,
          path: _chipPath,
        );
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// Drives a single line.
  void setValue(int offset, {required bool value}) =>
      setValues({offset: value});

  /// The event clock this request was made with.
  EventClock get eventClock => _eventClock;

  /// Reconfigures the held lines without releasing them.
  ///
  /// The lines stay claimed throughout, so nothing else can take them in the
  /// gap — which is the whole reason to prefer this over close-and-rerequest.
  ///
  /// [lines] must cover exactly the same offsets as the original request.
  /// [eventClock] defaults to the clock this request was made with; passing
  /// nothing therefore preserves it rather than reverting to monotonic.
  void reconfigure(
    List<LineConfig> lines, {
    EventClock? eventClock,
  }) {
    _checkOpen();
    final wanted = {for (final l in lines) l.offset};
    if (wanted.length != lines.length ||
        !wanted.containsAll(offsets) ||
        wanted.length != offsets.length) {
      throw ArgumentError.value(
        lines,
        'lines',
        'reconfigure must name exactly the offsets this request holds '
            '($offsets); got ${wanted.toList()..sort()}',
      );
    }
    final ordered = [
      for (final offset in offsets) lines.firstWhere((l) => l.offset == offset),
    ];
    final buf = calloc<gpio_v2_line_config>();
    try {
      // Defaults to the clock the request was CREATED with. A plain
      // `EventClock.monotonic` default here would silently revert a request
      // made with realtime or hardware timestamps.
      RequestEncoder(ordered, eventClock ?? _eventClock).writeTo(buf.ref);
      if (_syscalls.ioctl(_fd, GpioIoctl.v2LineSetConfig, buf.cast()) < 0) {
        throw GpioException(
          'GPIO_V2_LINE_SET_CONFIG',
          _syscalls.errno,
          path: _chipPath,
        );
      }
      _lines = List.unmodifiable(ordered);
      _indexOf = {
        for (var i = 0; i < ordered.length; i++) ordered[i].offset: i,
      };
    } finally {
      calloc.free(buf);
    }
  }

  /// Releases the lines. Idempotent.
  ///
  /// Stops the event isolate first, so nothing is left blocked on a descriptor
  /// that is about to be closed underneath it.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _reader?.close();
    _reader = null;
    final events = _events;
    _events = null;
    if (events != null) {
      // Only await when something is listening: a single-subscription
      // controller's close() future does not complete until its stream is
      // listened to and done, so awaiting an unlistened one hangs here forever
      // and the request descriptor is never released.
      if (events.hasListener) {
        await events.close();
      } else {
        unawaited(events.close());
      }
    }
    _syscalls.close(_fd);
  }

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  int _maskOfAll() {
    var mask = 0;
    for (var i = 0; i < _lines.length; i++) {
      mask |= 1 << i;
    }
    return mask;
  }

  int _requireHeld(int offset) {
    if (!_indexOf.containsKey(offset)) {
      throw ArgumentError.value(
        offset,
        'offset',
        'this request holds $offsets',
      );
    }
    return offset;
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('LineRequest for $offsets is closed');
    }
  }

  @override
  String toString() => 'LineRequest($offsets)';
}
