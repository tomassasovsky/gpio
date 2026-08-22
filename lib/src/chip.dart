import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gpio/src/events.dart';
import 'package:gpio/src/exception.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/ioctl.dart';
import 'package:gpio/src/ffi/libc.dart';
import 'package:gpio/src/ffi/names.dart';
import 'package:gpio/src/info_isolate.dart';
import 'package:gpio/src/line_config.dart';
import 'package:gpio/src/line_request.dart';
import 'package:gpio/src/models.dart';
import 'package:gpio/src/request_encoder.dart';
import 'package:gpio/src/syscalls.dart';

/// One GPIO controller, opened through its character device.
class GpioChip {
  GpioChip._(this._syscalls, this._fd, this.info);

  /// Opens the chip at [path], e.g. `/dev/gpiochip0`.
  ///
  /// Prefer [GpioChip.byLabel]: chip numbering follows probe order and is
  /// not stable across kernels or boards.
  factory GpioChip.byPath(String path, {Syscalls? syscalls}) {
    final sys = syscalls ?? LibcSyscalls();
    final fd = sys.open(path, OpenFlags.readWrite | OpenFlags.closeOnExec);
    if (fd < 0) {
      throw GpioException('open', sys.errno, path: path);
    }
    try {
      return GpioChip._(sys, fd, _readChipInfo(sys, fd, path));
    } on Object {
      sys.close(fd);
      rethrow;
    }
  }

  /// Opens the chip whose driver label is [label], e.g. `pinctrl-rp1`.
  ///
  /// This is the identifier worth hardcoding. On a Raspberry Pi 5 the RP1
  /// southbridge sits on PCIe and enumerates late, so the 40-pin header is
  /// `gpiochip4` on older kernels and `gpiochip0` on newer ones — while the
  /// label stays put.
  factory GpioChip.byLabel(String label, {Syscalls? syscalls}) {
    final sys = syscalls ?? LibcSyscalls();
    final tried = <String>[];
    for (final path in sys.listGpioChipPaths()) {
      final GpioChip chip;
      try {
        chip = GpioChip.byPath(path, syscalls: sys);
      } on GpioException catch (e) {
        // One unreadable chip must not hide a readable one further down the
        // list — a box can easily expose chips this user cannot open.
        tried.add('$path (unreadable: errno ${e.errno})');
        continue;
      }
      if (chip.info.label == label) return chip;
      tried.add('${chip.info.name} (${chip.info.label})');
      chip._closeDescriptor();
    }
    throw StateError(
      'No GPIO chip labelled "$label". Found: '
      '${tried.isEmpty ? 'no chips at all' : tried.join(', ')}.',
    );
  }

  /// Opens the chip with kernel device name [name], e.g. `gpiochip0`.
  factory GpioChip.byName(String name, {Syscalls? syscalls}) =>
      GpioChip.byPath('/dev/$name', syscalls: syscalls);

  /// Every GPIO chip on the system, opened.
  ///
  /// The caller owns them and must [close] each one.
  static List<GpioChip> list({Syscalls? syscalls}) {
    final sys = syscalls ?? LibcSyscalls();
    final opened = <GpioChip>[];
    try {
      for (final path in sys.listGpioChipPaths()) {
        opened.add(GpioChip.byPath(path, syscalls: sys));
      }
    } on Object {
      // Never strand descriptors the caller has no handle on.
      for (final chip in opened) {
        chip._closeDescriptor();
      }
      rethrow;
    }
    return opened;
  }

  final Syscalls _syscalls;
  final int _fd;
  var _closed = false;

  /// What the chip reports about itself.
  final GpioChipInfo info;

  static GpioChipInfo _readChipInfo(Syscalls sys, int fd, String path) {
    final buf = calloc<gpiochip_info>();
    try {
      if (sys.ioctl(fd, GpioIoctl.getChipInfo, buf.cast()) < 0) {
        throw GpioException('GPIO_GET_CHIPINFO', sys.errno, path: path);
      }
      return GpioChipInfo(
        name: readName(buf.ref.name, GPIO_MAX_NAME_SIZE),
        label: readName(buf.ref.label, GPIO_MAX_NAME_SIZE),
        lineCount: buf.ref.lines,
        path: path,
      );
    } finally {
      calloc.free(buf);
    }
  }

  /// Current configuration of the line at [offset].
  GpioLineInfo lineInfo(int offset) {
    _checkOpen();
    _checkOffset(offset);
    final buf = calloc<gpio_v2_line_info>();
    try {
      buf.ref.offset = offset;
      if (_ioctl(GpioIoctl.v2GetLineInfo, buf.cast()) < 0) {
        throw GpioException(
          'GPIO_V2_GET_LINEINFO',
          _syscalls.errno,
          path: info.path,
        );
      }
      return _decodeLineInfo(buf.ref);
    } finally {
      calloc.free(buf);
    }
  }

  /// The offset of the line named [name], or `null` if this chip has none.
  ///
  /// Line names come from the driver or device tree, so they survive
  /// renumbering just as [GpioChipInfo.label] does.
  int? findLine(String name) {
    for (var offset = 0; offset < info.lineCount; offset++) {
      if (lineInfo(offset).name == name) return offset;
    }
    return null;
  }

  /// Every line on the chip, in offset order.
  List<GpioLineInfo> allLines() =>
      [for (var i = 0; i < info.lineCount; i++) lineInfo(i)];

  /// Claims [lines] and returns a handle to them.
  ///
  /// All of the lines are claimed by a single ioctl, so values can later be
  /// read or written across the whole set atomically — ten footswitches are one
  /// descriptor, not ten.
  ///
  /// [consumer] is the label other processes see in `gpioinfo`; make it
  /// recognisable, because it is what an `EBUSY` message will name.
  LineRequest request({
    required List<LineConfig> lines,
    String consumer = 'dart-gpio',
    EventClock eventClock = EventClock.monotonic,
    int? eventBufferSize,
  }) {
    _checkOpen();
    if (lines.isEmpty) {
      throw ArgumentError.value(lines, 'lines', 'must not be empty');
    }
    if (lines.length > GPIO_V2_LINES_MAX) {
      throw ArgumentError.value(
        lines.length,
        'lines',
        'a single request may claim at most $GPIO_V2_LINES_MAX lines',
      );
    }
    final seen = <int>{};
    for (final line in lines) {
      _checkOffset(line.offset);
      if (!seen.add(line.offset)) {
        throw ArgumentError.value(
          line.offset,
          'lines',
          'offset appears more than once in the same request',
        );
      }
    }

    final req = calloc<gpio_v2_line_request>();
    try {
      for (var i = 0; i < lines.length; i++) {
        req.ref.offsets[i] = lines[i].offset;
      }
      req.ref.num_lines = lines.length;
      if (eventBufferSize != null) {
        req.ref.event_buffer_size = eventBufferSize;
      }
      writeName(req.ref.consumer, GPIO_MAX_NAME_SIZE, consumer);
      RequestEncoder(lines, eventClock).writeTo(req.ref.config);
      if (_ioctl(GpioIoctl.v2GetLine, req.cast()) < 0) {
        final errno = _syscalls.errno;
        throw GpioException(
          'GPIO_V2_GET_LINE',
          errno,
          path: info.path,
          consumer: errno == Errno.ebusy ? _busyConsumer(lines) : null,
        );
      }
      return LineRequest.fromFd(
        syscalls: _syscalls,
        fd: req.ref.fd,
        lines: lines,
        chipPath: info.path,
        eventClock: eventClock,
      );
    } finally {
      calloc.free(req);
    }
  }

  /// Best-effort: who already holds the first busy line, for the error message.
  String? _busyConsumer(List<LineConfig> lines) {
    for (final line in lines) {
      try {
        final held = lineInfo(line.offset);
        if (held.used && held.consumer.isNotEmpty) return held.consumer;
      } on GpioException {
        // The diagnostic is a courtesy; never let it mask the real failure.
      }
    }
    return null;
  }

  StreamController<LineInfoChanged>? _infoChanges;
  GpioInfoReader? _infoReader;
  final _watched = <int>{};

  /// Requests, releases and reconfigurations of [offsets], as the kernel sees
  /// them — including changes made by **other processes**.
  ///
  /// This is the honest answer to "who holds this pin?". [lineInfo] gives a
  /// snapshot that is stale the moment it returns; this reports each change as
  /// it happens. Without it, a collision only surfaces as `EBUSY` at request
  /// time, by which point there is nothing to do but fail.
  ///
  /// Watching costs nothing until something changes: the kernel pushes, so
  /// there is no polling.
  ///
  /// The stream is single-subscription and owns an isolate. The chip must stay
  /// open for as long as you listen — the events arrive on the chip's own
  /// descriptor — and [close] stops it.
  ///
  /// Note that a line this process requests will report itself here too: the
  /// kernel does not distinguish your own claims from anyone else's.
  Stream<LineInfoChanged> watchLineInfo(Iterable<int> offsets) {
    _checkOpen();
    final wanted = offsets.toList();
    if (wanted.isEmpty) {
      throw ArgumentError.value(offsets, 'offsets', 'must not be empty');
    }
    wanted.forEach(_checkOffset);

    final buf = calloc<gpio_v2_line_info>();
    try {
      for (final offset in wanted) {
        if (_watched.contains(offset)) continue;
        // The struct is reused across iterations, and the kernel fills it in on
        // success -- so every field must be reset, not just the offset.
        for (var i = 0; i < ffi.sizeOf<gpio_v2_line_info>(); i++) {
          buf.cast<ffi.Uint8>()[i] = 0;
        }
        buf.ref.offset = offset;
        if (_ioctl(GpioIoctl.v2WatchLineInfo, buf.cast()) < 0) {
          throw GpioException(
            'GPIO_V2_GET_LINEINFO_WATCH',
            _syscalls.errno,
            path: info.path,
          );
        }
        _watched.add(offset);
      }
    } finally {
      calloc.free(buf);
    }

    if (_infoChanges == null) _startInfoChanges();
    return _infoChanges!.stream;
  }

  /// Stops reporting changes for [offset].
  ///
  /// Unwatching a line that is not watched is a no-op rather than an error: the
  /// caller's intent — "I do not want reports for this line" — is satisfied
  /// either way.
  void unwatchLineInfo(int offset) {
    _checkOpen();
    _checkOffset(offset);
    if (!_watched.remove(offset)) return;
    final buf = calloc<ffi.Uint32>()..value = offset;
    try {
      if (_ioctl(GpioIoctl.unwatchLineInfo, buf.cast()) < 0) {
        throw GpioException(
          'GPIO_GET_LINEINFO_UNWATCH',
          _syscalls.errno,
          path: info.path,
        );
      }
    } finally {
      calloc.free(buf);
    }
  }

  /// The lines currently watched by [watchLineInfo], in ascending order.
  List<int> get watchedLines => _watched.toList()..sort();

  void _startInfoChanges() {
    late final StreamController<LineInfoChanged> controller;
    StreamSubscription<RawInfoEvent>? subscription;

    controller = StreamController<LineInfoChanged>(
      onListen: () async {
        try {
          final reader = await _syscalls.openLineInfoEvents(_fd);
          _infoReader = reader;
          // The chip may have been closed while the isolate was starting.
          if (_closed) {
            await reader.close();
            await controller.close();
            return;
          }
          subscription = reader.events.listen(
            (raw) => controller.add(
              LineInfoChanged(
                kind: LineChangeKind.fromValue(raw.changeType),
                info: lineInfoFromFields(
                  offset: raw.offset,
                  name: raw.name,
                  consumer: raw.consumer,
                  flags: raw.flags,
                  debounceMicros: raw.debounceMicros,
                ),
                timestampNs: raw.timestampNanos,
              ),
            ),
            onDone: controller.close,
            onError: controller.addError,
          );
        } on Object catch (error, stack) {
          if (!controller.isClosed) {
            controller.addError(error, stack);
            unawaited(controller.close());
          }
        }
      },
      onCancel: () async {
        await subscription?.cancel();
        await _infoReader?.close();
        _infoReader = null;
        _infoChanges = null;
      },
    );
    _infoChanges = controller;
  }

  /// Releases the chip descriptor. Idempotent.
  ///
  /// Does not affect any [LineRequest] taken from it: the kernel ties line
  /// ownership to the request's own descriptor, so requests outlive their chip.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Stop the watcher before the descriptor goes: it is blocked in poll() on
    // this exact fd, and descriptor numbers are reused the instant they are
    // free. This is why close() is async -- the same race the edge-event path
    // already had to fix.
    await _infoReader?.close();
    _infoReader = null;
    final changes = _infoChanges;
    _infoChanges = null;
    if (changes != null && !changes.isClosed) {
      // A controller nobody listened to never completes its close(); awaiting
      // one would hang here forever.
      if (changes.hasListener) {
        await changes.close();
      } else {
        unawaited(changes.close());
      }
    }
    _syscalls.close(_fd);
  }

  /// Closes just the descriptor, for chips that provably have no watcher.
  ///
  /// [GpioChip.byLabel] and [GpioChip.list] open chips and discard the ones
  /// they do not want. Those have never been handed to a caller, so nothing
  /// could have started a line-info stream on them — which makes the async
  /// half of [close] dead weight in a place that cannot await anyway.
  void _closeDescriptor() {
    if (_closed) return;
    _closed = true;
    _syscalls.close(_fd);
  }

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  int _ioctl(int request, ffi.Pointer<ffi.Void> argp) =>
      _syscalls.ioctl(_fd, request, argp);

  void _checkOpen() {
    if (_closed) {
      throw StateError('GpioChip ${info.name} is closed');
    }
  }

  void _checkOffset(int offset) {
    if (offset < 0 || offset >= info.lineCount) {
      throw RangeError.range(
        offset,
        0,
        info.lineCount - 1,
        'offset',
        '${info.name} has ${info.lineCount} lines',
      );
    }
  }

  @override
  String toString() => 'GpioChip(${info.name}, ${info.label})';
}

GpioLineInfo _decodeLineInfo(gpio_v2_line_info raw) {
  var debounce = 0;
  for (var i = 0; i < raw.num_attrs; i++) {
    final attr = raw.attrs[i];
    if (attr.id == gpio_v2_line_attr_id.GPIO_V2_LINE_ATTR_ID_DEBOUNCE.value) {
      debounce = attr.unnamed.debounce_period_us;
    }
  }
  return lineInfoFromFields(
    offset: raw.offset,
    name: readName(raw.name, GPIO_MAX_NAME_SIZE),
    consumer: readName(raw.consumer, GPIO_MAX_NAME_SIZE),
    flags: raw.flags,
    debounceMicros: debounce,
  );
}

/// Builds a [GpioLineInfo] from the flat fields of a `gpio_v2_line_info`.
///
/// Separate from the struct so the line-info watcher can reuse it: a `Struct`
/// is a view onto native memory the reader isolate immediately reuses, so what
/// crosses the isolate boundary is these fields, not the struct.
GpioLineInfo lineInfoFromFields({
  required int offset,
  required String name,
  required String consumer,
  required int flags,
  required int debounceMicros,
}) {
  return GpioLineInfo(
    offset: offset,
    name: name,
    consumer: consumer,
    direction: flags & LineFlag.output != 0
        ? LineDirection.output
        : LineDirection.input,
    used: flags & LineFlag.used != 0,
    activeLow: flags & LineFlag.activeLow != 0,
    bias: switch (flags) {
      _ when flags & LineFlag.biasPullUp != 0 => Bias.pullUp,
      _ when flags & LineFlag.biasPullDown != 0 => Bias.pullDown,
      _ when flags & LineFlag.biasDisabled != 0 => Bias.disabled,
      _ => Bias.asIs,
    },
    drive: switch (flags) {
      _ when flags & LineFlag.openDrain != 0 => Drive.openDrain,
      _ when flags & LineFlag.openSource != 0 => Drive.openSource,
      _ => Drive.pushPull,
    },
    edge: switch (flags & (LineFlag.edgeRising | LineFlag.edgeFalling)) {
      const (LineFlag.edgeRising | LineFlag.edgeFalling) => Edge.both,
      LineFlag.edgeRising => Edge.rising,
      LineFlag.edgeFalling => Edge.falling,
      _ => Edge.none,
    },
    debouncePeriod: Duration(microseconds: debounceMicros),
  );
}
