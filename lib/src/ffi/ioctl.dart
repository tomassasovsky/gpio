import 'dart:ffi' as ffi;

import 'package:gpio/src/ffi/gpio_uapi.dart';

/// The `_IOC` request-number encoding shared by every architecture Dart runs
/// on (the `asm-generic` layout: x86, ARM, ARM64, RISC-V).
///
/// Request numbers are **computed**, never hardcoded, because the encoding
/// includes `sizeof(argument struct)`. If a generated [ffi.Struct] ever stops
/// matching the kernel's layout, the computed number stops matching the one the
/// kernel expects and the call fails with `ENOTTY` — loudly, at the boundary —
/// instead of the kernel reading or writing past the end of our buffer.
///
/// See `include/uapi/asm-generic/ioctl.h`.
class Ioc {
  const Ioc._();

  static const _nrBits = 8;
  static const _typeBits = 8;
  static const _sizeBits = 14;

  static const _nrShift = 0;
  static const int _typeShift = _nrShift + _nrBits;
  static const int _sizeShift = _typeShift + _typeBits;
  static const int _dirShift = _sizeShift + _sizeBits;

  static const _dirNone = 0;
  static const _dirWrite = 1;
  static const _dirRead = 2;

  /// The largest `size` the encoding can carry. A struct beyond this cannot be
  /// addressed by an ioctl at all, so it is a programming error, not a runtime
  /// condition.
  static const int maxSize = (1 << _sizeBits) - 1;

  static int _encode(int dir, int type, int nr, int size) {
    assert(size <= maxSize, 'ioctl argument struct exceeds _IOC size field');
    return (dir << _dirShift) |
        (type << _typeShift) |
        (nr << _nrShift) |
        (size << _sizeShift);
  }

  /// `_IO(type, nr)` — no argument.
  static int io(int type, int nr) => _encode(_dirNone, type, nr, 0);

  /// `_IOR(type, nr, T)` — kernel writes into the argument.
  ///
  /// [size] is the argument struct's size; pass `ffi.sizeOf<T>()`. It cannot be
  /// a type parameter: `sizeOf` needs a concrete type at compile time and
  /// rejects a type variable.
  static int ior(int type, int nr, int size) =>
      _encode(_dirRead, type, nr, size);

  /// `_IOW(type, nr, T)` — kernel reads the argument.
  static int iow(int type, int nr, int size) =>
      _encode(_dirWrite, type, nr, size);

  /// `_IOWR(type, nr, T)` — argument is read and written.
  static int iowr(int type, int nr, int size) =>
      _encode(_dirRead | _dirWrite, type, nr, size);
}

/// The GPIO character-device ioctls this package uses.
///
/// Only the **v2** ABI is bound. The v1 request/event ioctls
/// (`GPIO_GET_LINEHANDLE_IOCTL` and friends) are marked deprecated in the
/// kernel header and are deliberately absent: there is no fallback path, so
/// there is no way to silently end up on the older ABI.
class GpioIoctl {
  const GpioIoctl._();

  /// `0xB4` — the GPIO ioctl type, from `include/uapi/linux/gpio.h`.
  static const type = 0xB4;

  /// `GPIO_GET_CHIPINFO_IOCTL` — name, label and line count for a chip.
  static final int getChipInfo =
      Ioc.ior(type, 0x01, ffi.sizeOf<gpiochip_info>());

  /// `GPIO_V2_GET_LINEINFO_IOCTL` — current configuration of one line.
  static final int v2GetLineInfo =
      Ioc.iowr(type, 0x05, ffi.sizeOf<gpio_v2_line_info>());

  /// `GPIO_V2_GET_LINEINFO_WATCH_IOCTL` — as above, and report later changes.
  static final int v2WatchLineInfo =
      Ioc.iowr(type, 0x06, ffi.sizeOf<gpio_v2_line_info>());

  /// `GPIO_V2_GET_LINE_IOCTL` — request lines and receive a request fd.
  static final int v2GetLine =
      Ioc.iowr(type, 0x07, ffi.sizeOf<gpio_v2_line_request>());

  /// `GPIO_GET_LINEINFO_UNWATCH_IOCTL` — stop watching one line.
  static final int unwatchLineInfo =
      Ioc.iowr(type, 0x0C, ffi.sizeOf<ffi.Uint32>());

  /// `GPIO_V2_LINE_SET_CONFIG_IOCTL` — reconfigure an existing request.
  static final int v2LineSetConfig =
      Ioc.iowr(type, 0x0D, ffi.sizeOf<gpio_v2_line_config>());

  /// `GPIO_V2_LINE_GET_VALUES_IOCTL` — read a masked set of lines at once.
  static final int v2LineGetValues =
      Ioc.iowr(type, 0x0E, ffi.sizeOf<gpio_v2_line_values>());

  /// `GPIO_V2_LINE_SET_VALUES_IOCTL` — drive a masked set of lines at once.
  static final int v2LineSetValues =
      Ioc.iowr(type, 0x0F, ffi.sizeOf<gpio_v2_line_values>());
}
