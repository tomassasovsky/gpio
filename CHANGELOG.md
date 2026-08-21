# Changelog

## 0.1.0

First release.

- Linux GPIO over `/dev/gpiochip*` using the **v2** userspace ABI, in pure Dart
  via `dart:ffi` and libc. No native library, no bundled binaries.
- Chip discovery by **label** and line lookup by **name**, so code survives the
  probe-order renumbering that moves a Pi 5's header between `gpiochip0` and
  `gpiochip4`.
- Requests of up to 64 lines claimed in one ioctl, read and written atomically.
  Initial output values are applied by the claiming ioctl, so a line never
  passes through an undefined state.
- Full per-line configuration: direction, bias, drive, active-low, edge
  detection, and **kernel-side debounce**.
- Edge events as a `Stream`, timestamped by the kernel in the interrupt
  handler. `timestampNs` carries the raw nanoseconds; `timestamp` is a
  microsecond-resolution `Duration` convenience.
- `LineEventsDropped` — when the kernel's event FIFO overflows, the loss is
  reported rather than silent. The v2 ABI's sequence numbers are what make this
  possible.
- `GpioException` maps errno to an actionable message: `EACCES` gives the udev
  rule, `EBUSY` names the consumer holding the line, `ENOTTY` explains that the
  kernel predates the v2 interface.
- `package:gpio/gpio_testing.dart` — an in-memory kernel for testing GPIO code
  on machines without GPIO.

Requires Linux 5.10 or newer. There is no v1 fallback, by design.
