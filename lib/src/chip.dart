import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:gpio/src/exception.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/ioctl.dart';
import 'package:gpio/src/ffi/libc.dart';
import 'package:gpio/src/line_config.dart';
import 'package:gpio/src/line_request.dart';
import 'package:gpio/src/models.dart';
import 'package:gpio/src/request_encoder.dart';
import 'package:gpio/src/syscalls.dart';

/// Reads a fixed-width, NUL-padded C name field into a Dart string.
///
/// `ffi.Char` is signed on x86-64 and unsigned on ARM, so a byte above 0x7F
/// arrives as a negative number on one and a positive one on the other. Masking
/// to a byte before decoding keeps both honest — and the field is UTF-8, not
/// Latin-1, so it is decoded as such rather than treated as code units.
String readName(ffi.Array<ffi.Char> array, int capacity) {
  final bytes = <int>[];
  for (var i = 0; i < capacity; i++) {
    final c = array[i] & 0xFF;
    if (c == 0) break;
    bytes.add(c);
  }
  // Malformed bytes become U+FFFD: a chip with an odd name is not a reason to
  // throw out of a discovery loop.
  return const Utf8Decoder(allowMalformed: true).convert(bytes);
}

/// Writes [value] into a fixed-width C name field as UTF-8, truncating on a
/// character boundary if needed and always leaving room for the NUL.
void writeName(ffi.Array<ffi.Char> array, int capacity, String value) {
  var bytes = const Utf8Encoder().convert(value);
  if (bytes.length > capacity - 1) {
    // Truncate without splitting a multi-byte sequence: back off to the last
    // byte that is not a UTF-8 continuation byte (0b10xxxxxx).
    var end = capacity - 1;
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    bytes = bytes.sublist(0, end);
  }
  for (var i = 0; i < bytes.length; i++) {
    array[i] = bytes[i];
  }
  array[bytes.length] = 0;
}

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
      chip.close();
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
        chip.close();
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

  /// Releases the chip descriptor. Idempotent.
  ///
  /// Does not affect any [LineRequest] taken from it: the kernel ties line
  /// ownership to the request's own descriptor, so requests outlive their chip.
  void close() {
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
  final flags = raw.flags;
  var debounce = Duration.zero;
  for (var i = 0; i < raw.num_attrs; i++) {
    final attr = raw.attrs[i];
    if (attr.id == gpio_v2_line_attr_id.GPIO_V2_LINE_ATTR_ID_DEBOUNCE.value) {
      debounce = Duration(microseconds: attr.unnamed.debounce_period_us);
    }
  }
  return GpioLineInfo(
    offset: raw.offset,
    name: readName(raw.name, GPIO_MAX_NAME_SIZE),
    consumer: readName(raw.consumer, GPIO_MAX_NAME_SIZE),
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
    debouncePeriod: debounce,
  );
}
