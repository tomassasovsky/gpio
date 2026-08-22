# Changelog

## 0.2.0

**Breaking:** `GpioChip.close()` returns a `Future` and must be awaited.

A line-info watcher blocks in `poll(2)` on the chip's own descriptor, so the
chip cannot close that descriptor until the watcher has actually left the
syscall — descriptor numbers are reused the instant they are free, and a
straggling read would land on an unrelated file. `LineRequest.close()` is
already async for exactly this reason; the chip now matches. Add `await`.

- **`GpioChip.watchLineInfo(offsets)`** — a `Stream<LineInfoChanged>` of
  requests, releases and reconfigurations, as the kernel reports them,
  *including changes made by other processes*. `unwatchLineInfo(offset)` stops
  reporting one line; `watchedLines` says which are being watched.

  `lineInfo()` gives a snapshot that is stale the moment it returns. Until now
  a collision with another process surfaced only as `EBUSY` at request time,
  too late to do anything but fail.
- `LineInfoChanged` carries the change kind, the line's state *after* the
  change, and the kernel's timestamp. It is deliberately **not** part of the
  `LineEvent` sealed hierarchy: these arrive on a different descriptor and mean
  something different, and adding a variant to a sealed type would break every
  exhaustive `switch` already written against it.
- `LineChangeKind.fromValue` maps an unrecognised kind to `reconfigured` rather
  than throwing, so a future kernel adding a fourth type cannot kill a running
  program.
- `FakeKernel` models watches, so consumers can test this without hardware.

The ioctls were already bound in the ABI layer; only the public surface was
missing.

## 0.1.1

- Shortened the package description to the 60-180 characters pub.dev scores.
  0.1.0 shipped at ~258 and took 0/10 on "Provide a valid pubspec.yaml" for it;
  the long-form pitch lives in the README, where it belongs. A published
  pubspec is immutable, so this needed a release of its own. A test now pins
  the range.

No API changes.

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
  rule, `EBUSY` names the consumer holding the line, `ENOTTY` says the path is
  not a gpiochip, and `EINVAL` — which is what a kernel older than 5.10 actually
  returns for a v2 ioctl — says so.
- `package:gpio/gpio_testing.dart` — an in-memory kernel for testing GPIO code
  on machines without GPIO.

Requires Linux 5.10 or newer. There is no v1 fallback, by design.
