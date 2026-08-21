import 'dart:async';
import 'dart:ffi';

import 'package:gpio/src/chip.dart';
import 'package:gpio/src/event_isolate.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/ioctl.dart';
import 'package:gpio/src/ffi/libc.dart';
import 'package:gpio/src/line_config.dart';
import 'package:gpio/src/syscalls.dart';

/// A simulated GPIO chip for [FakeKernel].
class FakeChip {
  /// Creates a chip with [lineCount] lines.
  FakeChip({
    required this.name,
    required this.label,
    required this.lineCount,
    Map<int, String>? lineNames,
  }) : lineNames = lineNames ?? const {} {
    _levels = List.filled(lineCount, false);
  }

  /// Kernel device name, e.g. `gpiochip0`.
  final String name;

  /// Driver label, e.g. `pinctrl-rp1`.
  final String label;

  /// How many lines the chip has.
  final int lineCount;

  /// Names the "device tree" gives particular lines.
  final Map<int, String> lineNames;

  late List<bool> _levels;

  /// offset -> consumer label, for lines currently claimed.
  final Map<int, String> owners = {};

  /// The chip's device path.
  String get path => '/dev/$name';

  /// Physical level of [offset], as a test would set it from outside.
  ///
  /// This is the *voltage*, before any `activeLow` inversion.
  bool level(int offset) => _levels[offset];

  /// Drives [offset] from the outside world, as hardware would.
  ///
  /// If a request holds the line with edge detection, this generates an edge
  /// event exactly as the kernel would — including the sequence numbers.
  void setLevel(int offset, {required bool value}) {
    final changed = _levels[offset] != value;
    _levels[offset] = value;
    if (changed) onEdge?.call(offset, level: value);
  }

  /// Drives several lines at once.
  void setLevels(Map<int, bool> values) =>
      values.forEach((k, v) => setLevel(k, value: v));

  /// Installed by [FakeKernel] so level changes become edge events.
  void Function(int offset, {required bool level})? onEdge;
}

/// A [Syscalls] implementation backed by an in-memory model of the GPIO
/// character device.
///
/// Enough of the real contract to be worth testing against: line ownership and
/// `EBUSY`, masked atomic reads and writes, `activeLow` inversion, initial
/// output values applied at request time, and per-line flag and debounce
/// attributes decoded exactly as the kernel would decode them.
class FakeKernel implements Syscalls {
  /// Creates a fake kernel exposing [chips].
  FakeKernel(this.chips);

  /// A fake with one 8-line chip, which is enough for most tests.
  factory FakeKernel.single({
    String name = 'gpiochip0',
    String label = 'fake-pinctrl',
    int lineCount = 8,
    Map<int, String>? lineNames,
  }) =>
      FakeKernel([
        FakeChip(
          name: name,
          label: label,
          lineCount: lineCount,
          lineNames: lineNames,
        ),
      ]);

  /// The chips this kernel exposes.
  final List<FakeChip> chips;

  int _nextFd = 3;
  final Map<int, FakeChip> _chipFds = {};
  final Map<int, _FakeRequest> _requestFds = {};
  int _errno = 0;

  /// Descriptors opened and not yet closed. A leak in the code under test
  /// shows up here.
  int get openDescriptors => _chipFds.length + _requestFds.length;

  /// Every ioctl request number issued, in order — so a test can assert that
  /// a v1 ioctl was never attempted.
  final List<int> ioctlLog = [];

  final Map<int, _FakeEvents> _eventReaders = {};
  int _seqno = 0;

  /// Drops this many upcoming events instead of delivering them, without
  /// reusing their sequence numbers — exactly what the kernel's per-request
  /// FIFO does when it overflows.
  ///
  /// The point of the v2 ABI's sequence numbers is that this becomes provable
  /// rather than silent, so it has to be reproducible in a test.
  int dropNextEvents = 0;

  @override
  Future<GpioEventReader> openEvents(int fd) async {
    final request = _requestFds[fd];
    if (request == null) {
      throw StateError('no such request descriptor: $fd');
    }
    final reader = _FakeEvents(request);
    _eventReaders[fd] = reader;
    request.chip.onEdge = _emit;
    return reader.asReader();
  }

  void _emit(int offset, {required bool level}) {
    for (final reader in _eventReaders.values) {
      final index = reader.request.indexOf(offset);
      if (index == null) continue;
      if (!reader.request.wantsEdge(offset, rising: level)) continue;

      _seqno++;
      if (dropNextEvents > 0) {
        // Consumed a sequence number but delivered nothing — the gap is what
        // makes the loss detectable downstream.
        dropNextEvents--;
        continue;
      }
      final logical = reader.request.isActiveLow(offset) ? !level : level;
      reader.controller.add(
        (
          offset: offset,
          id: logical ? 1 : 2, // 1 = rising, 2 = falling
          timestampNanos: _seqno * 1000000,
          seqno: _seqno,
          lineSeqno: _seqno,
        ),
      );
    }
  }

  @override
  int get errno => _errno;

  @override
  List<String> listGpioChipPaths() => [for (final c in chips) c.path];

  @override
  int open(String path, int flags) {
    final chip = chips.where((c) => c.path == path).firstOrNull;
    if (chip == null) {
      _errno = Errno.enoent;
      return -1;
    }
    final fd = _nextFd++;
    _chipFds[fd] = chip;
    return fd;
  }

  @override
  int close(int fd) {
    unawaited(_eventReaders.remove(fd)?.controller.close() ?? Future.value());
    final request = _requestFds.remove(fd);
    if (request != null) {
      request.offsets.forEach(request.chip.owners.remove);
      return 0;
    }
    if (_chipFds.remove(fd) != null) return 0;
    _errno = Errno.ebadf;
    return -1;
  }

  @override
  int read(int fd, Pointer<Void> buf, int count) {
    _errno = Errno.eagain;
    return -1;
  }

  @override
  int ioctl(int fd, int request, Pointer<Void> argp) {
    ioctlLog.add(request);
    if (request == GpioIoctl.getChipInfo) return _chipInfo(fd, argp);
    if (request == GpioIoctl.v2GetLineInfo) return _lineInfo(fd, argp);
    if (request == GpioIoctl.v2GetLine) return _getLine(fd, argp);
    if (request == GpioIoctl.v2LineGetValues) return _getValues(fd, argp);
    if (request == GpioIoctl.v2LineSetValues) return _setValues(fd, argp);
    if (request == GpioIoctl.v2LineSetConfig) return _setConfig(fd, argp);
    _errno = Errno.enotty;
    return -1;
  }

  int _chipInfo(int fd, Pointer<Void> argp) {
    final chip = _chipFds[fd];
    if (chip == null) {
      _errno = Errno.ebadf;
      return -1;
    }
    final info = argp.cast<gpiochip_info>().ref;
    writeName(info.name, GPIO_MAX_NAME_SIZE, chip.name);
    writeName(info.label, GPIO_MAX_NAME_SIZE, chip.label);
    info.lines = chip.lineCount;
    return 0;
  }

  int _lineInfo(int fd, Pointer<Void> argp) {
    final chip = _chipFds[fd];
    if (chip == null) {
      _errno = Errno.ebadf;
      return -1;
    }
    final info = argp.cast<gpio_v2_line_info>().ref;
    final offset = info.offset;
    if (offset < 0 || offset >= chip.lineCount) {
      _errno = Errno.einval;
      return -1;
    }
    writeName(info.name, GPIO_MAX_NAME_SIZE, chip.lineNames[offset] ?? '');
    final owner = chip.owners[offset];
    writeName(info.consumer, GPIO_MAX_NAME_SIZE, owner ?? '');
    final held = _requestFds.values
        .where((r) => r.chip == chip && r.indexOf(offset) != null)
        .firstOrNull;
    info
      ..flags = held == null
          ? 0
          : held.flagsFor(offset) | (owner == null ? 0 : LineFlag.used)
      ..num_attrs = 0;
    if (held != null) {
      final debounce = held.debounceFor(offset);
      if (debounce > 0) {
        info.num_attrs = 1;
        info.attrs[0]
          ..id = gpio_v2_line_attr_id.GPIO_V2_LINE_ATTR_ID_DEBOUNCE.value
          ..unnamed.debounce_period_us = debounce;
      }
    }
    return 0;
  }

  int _getLine(int fd, Pointer<Void> argp) {
    final chip = _chipFds[fd];
    if (chip == null) {
      _errno = Errno.ebadf;
      return -1;
    }
    final req = argp.cast<gpio_v2_line_request>().ref;
    final consumer = readName(req.consumer, GPIO_MAX_NAME_SIZE);
    final offsets = [for (var i = 0; i < req.num_lines; i++) req.offsets[i]];

    for (final offset in offsets) {
      if (offset < 0 || offset >= chip.lineCount) {
        _errno = Errno.einval;
        return -1;
      }
      if (chip.owners.containsKey(offset)) {
        _errno = Errno.ebusy;
        return -1;
      }
    }

    final decoded = _FakeRequest.decode(chip, offsets, req.config);
    for (final offset in offsets) {
      chip.owners[offset] = consumer;
    }
    // Initial output values are applied by this same ioctl, so a line never
    // passes through an undefined state on its way to the requested value.
    decoded.applyOutputValues();
    final requestFd = _nextFd++;
    _requestFds[requestFd] = decoded;
    req.fd = requestFd;
    return 0;
  }

  int _getValues(int fd, Pointer<Void> argp) {
    final request = _requestFds[fd];
    if (request == null) {
      _errno = Errno.ebadf;
      return -1;
    }
    final values = argp.cast<gpio_v2_line_values>().ref;
    var bits = 0;
    for (var i = 0; i < request.offsets.length; i++) {
      if (values.mask & (1 << i) == 0) continue;
      final offset = request.offsets[i];
      final level = request.chip.level(offset);
      final logical = request.isActiveLow(offset) ? !level : level;
      if (logical) bits |= 1 << i;
    }
    values.bits = bits;
    return 0;
  }

  int _setValues(int fd, Pointer<Void> argp) {
    final request = _requestFds[fd];
    if (request == null) {
      _errno = Errno.ebadf;
      return -1;
    }
    final values = argp.cast<gpio_v2_line_values>().ref;
    // Validate the whole mask first. The real kernel rejects the ioctl without
    // driving anything, so a fake that writes as it walks would hide a
    // half-applied write that cannot actually happen.
    for (var i = 0; i < request.offsets.length; i++) {
      if (values.mask & (1 << i) == 0) continue;
      if (!request.isOutput(request.offsets[i])) {
        _errno = Errno.eperm;
        return -1;
      }
    }
    for (var i = 0; i < request.offsets.length; i++) {
      if (values.mask & (1 << i) == 0) continue;
      final offset = request.offsets[i];
      final logical = values.bits & (1 << i) != 0;
      request.chip.setLevel(
        offset,
        value: request.isActiveLow(offset) ? !logical : logical,
      );
    }
    return 0;
  }

  int _setConfig(int fd, Pointer<Void> argp) {
    final request = _requestFds[fd];
    if (request == null) {
      _errno = Errno.ebadf;
      return -1;
    }
    request
      ..applyConfig(argp.cast<gpio_v2_line_config>().ref)
      ..applyOutputValues();
    return 0;
  }
}

/// The fake kernel's view of one line request: the decoded flag and debounce
/// attributes, resolved per line exactly as the kernel resolves them.
class _FakeRequest {
  _FakeRequest(this.chip, this.offsets);

  factory _FakeRequest.decode(
    FakeChip chip,
    List<int> offsets,
    gpio_v2_line_config config,
  ) =>
      _FakeRequest(chip, offsets)..applyConfig(config);

  final FakeChip chip;
  final List<int> offsets;

  final Map<int, int> _flags = {};
  final Map<int, int> _debounce = {};

  /// Bitmask of initial output values, by request index.
  int initialValues = 0;

  int? indexOf(int offset) {
    final i = offsets.indexOf(offset);
    return i < 0 ? null : i;
  }

  void applyConfig(gpio_v2_line_config config) {
    // Reset: a reconfigure replaces the previous configuration wholesale,
    // it does not accumulate on top of it.
    initialValues = 0;
    for (var i = 0; i < offsets.length; i++) {
      _flags[offsets[i]] = config.flags;
      _debounce[offsets[i]] = 0;
    }
    for (var a = 0; a < config.num_attrs; a++) {
      final attr = config.attrs[a];
      final mask = attr.mask;
      for (var i = 0; i < offsets.length; i++) {
        if (mask & (1 << i) == 0) continue;
        switch (attr.attr.id) {
          case 1: // FLAGS — replaces the defaults for these lines
            _flags[offsets[i]] = attr.attr.unnamed.flags;
          case 2: // OUTPUT_VALUES
            if (attr.attr.unnamed.values & (1 << i) != 0) {
              initialValues |= 1 << i;
            }
          case 3: // DEBOUNCE
            _debounce[offsets[i]] = attr.attr.unnamed.debounce_period_us;
        }
      }
    }
  }

  /// Drives every output line to its configured value.
  ///
  /// The kernel applies OUTPUT_VALUES on both GPIO_V2_GET_LINE and
  /// GPIO_V2_LINE_SET_CONFIG, so the fake has to as well -- otherwise a
  /// reconfigure to an output would look like it silently did nothing.
  void applyOutputValues() {
    for (var i = 0; i < offsets.length; i++) {
      final offset = offsets[i];
      if (!isOutput(offset)) continue;
      final wanted = initialValues & (1 << i) != 0;
      chip.setLevel(offset, value: isActiveLow(offset) ? !wanted : wanted);
    }
  }

  int flagsFor(int offset) => _flags[offset] ?? 0;

  int debounceFor(int offset) => _debounce[offset] ?? 0;

  bool isOutput(int offset) => flagsFor(offset) & LineFlag.output != 0;

  bool isActiveLow(int offset) => flagsFor(offset) & LineFlag.activeLow != 0;

  /// Whether this line asked for the edge a transition to [rising] produces.
  bool wantsEdge(int offset, {required bool rising}) {
    final flags = flagsFor(offset);
    final logicalRising = isActiveLow(offset) ? !rising : rising;
    return logicalRising
        ? flags & LineFlag.edgeRising != 0
        : flags & LineFlag.edgeFalling != 0;
  }
}

/// A [GpioEventReader] fed by [FakeKernel] rather than by a real isolate.
class _FakeEvents {
  _FakeEvents(this.request);

  final _FakeRequest request;
  final StreamController<RawLineEvent> controller =
      StreamController<RawLineEvent>();

  GpioEventReader asReader() => GpioEventReader.forTesting(
        events: controller.stream,
        onClose: controller.close,
      );
}
