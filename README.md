# gpio

Linux GPIO from pure Dart, over the `/dev/gpiochip*` character device using the
**v2 userspace ABI**.

No native library. No bundled binaries. No `apt install` step. Just `dart:ffi`
and the libc that is already in your process.

> **Status: pre-release (0.1.0).** The API is complete and tested; it has not
> yet been exercised on real hardware, so treat it as unproven on a live board
> until it has been.

## Why another GPIO package

Because the v2 ABI carries three things v1 does not, and every existing Dart
option gives up at least one of them:

- **Kernel-side debounce**, so contact bounce is filtered below userspace
  instead of by a timer you wrote.
- **Event sequence numbers**, so when the kernel's buffer overflows and edges
  are dropped, you find out. Every other Dart package silently loses them.
- **A selectable event clock**, so timestamps mean something specific.

Edge events arrive as a `Stream`, timestamped by the kernel at the interrupt —
so scheduling affects when you *see* an event, never what time it says. The raw
`timestampNs` is what the event carries, because Dart's `Duration` is
microsecond-resolution and would quietly drop the low three digits; `timestamp`
is there as a convenience when that does not matter.

## Requirements

- Linux 5.10 or newer (when the v2 ABI landed). There is no v1 fallback, by
  design — you cannot silently end up on the deprecated ABI. An older kernel
  answers `EINVAL` to every v2 ioctl (not `ENOTTY`, which means "not a gpiochip"),
  and the error message says so.
- Access to `/dev/gpiochip*`. Root works; a udev rule is better:

  ```
  # /etc/udev/rules.d/60-gpio.rules
  SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
  ```

  then add your user to the `gpio` group and re-login.

## Usage

```dart
import 'package:gpio/gpio.dart';

final chip = GpioChip.byLabel('pinctrl-rp1');

final request = chip.request(
  consumer: 'my-app',
  lines: [
    LineConfig.input(17,
      bias: Bias.pullUp,
      activeLow: true,
      edge: Edge.both,
      debounce: Duration(milliseconds: 5)),
    LineConfig.output(27, initialValue: false),
  ],
);

// One ioctl, one atomic sample across every held line.
print(request.getValues());          // {17: false, 27: false}
request.setValue(27, value: true);

request.events.listen((event) => switch (event) {
  LineEdgeEvent(:final edge, :final timestampNs) =>
    print('$edge at $timestampNs ns'),
  LineEventsDropped(:final count) =>
    print('the kernel dropped $count edges'),
});

await request.close();
await chip.close();
```

Runnable versions of both halves are in [`example/`](example/).

## Knowing when someone else takes a line

`lineInfo()` is a snapshot, stale the moment it returns. `watchLineInfo` reports
each change as the kernel sees it — **including changes made by other
processes**:

```dart
final chip = GpioChip.byLabel('pinctrl-rp1');

chip.watchLineInfo([17, 27]).listen((change) {
  switch (change.kind) {
    case LineChangeKind.requested:
      print('line ${change.offset} taken by "${change.info.consumer}"');
    case LineChangeKind.released:
      print('line ${change.offset} is free again');
    case LineChangeKind.reconfigured:
      print('line ${change.offset} reconfigured');
  }
});
```

Without this, a collision with another process shows up only as `EBUSY` at
request time — by which point there is nothing to do but fail. A daemon holding
a footswitch learns that someone ran `gpioset` against the same line; a service
restarting learns the previous instance let go.

Watching costs nothing until something changes: the kernel pushes, so there is
no polling. `unwatchLineInfo(offset)` stops one line, and closing the chip stops
everything.

Note that lines **this** process requests report here too — the kernel does not
distinguish your own claims from anyone else's.

## Testing your own code

`FakeKernel` models the character device in memory, so code that talks to GPIO
is testable on a machine that has none:

```dart
import 'package:gpio/gpio_testing.dart';

final fake = FakeChip(name: 'gpiochip0', label: 'test', lineCount: 8);
final chip = GpioChip.byLabel('test', syscalls: FakeKernel([fake]));

fake.setLevel(3, value: true);       // drive a pin from "outside"
expect(request.getValue(3), isTrue);
```

It models ownership and `EBUSY`, masked atomic access, `activeLow` inversion,
kernel debounce, and edge events with sequence numbers — including
`dropNextEvents`, which reproduces a FIFO overflow so you can test that your
code notices.

## Finding your chip

Look chips up by **label**, not by index:

```dart
final chip = GpioChip.byLabel('pinctrl-rp1');   // Raspberry Pi 5
```

Chip numbering is assigned by probe order, so it moves. On the Raspberry Pi 5
the RP1 southbridge sits on PCIe and enumerates late: older kernels expose the
40-pin header as `gpiochip4`, kernels after mid-2024 renumber it to
`gpiochip0`. Code with a hardcoded index is a bug waiting for a kernel update.

## Platform support

| target | how GPIO is reached there | status |
|---|---|---|
| Linux | `/dev/gpiochipN`, uAPI v2 | ✅ supported |
| Android | the same character device (root + SELinux permits) | should work, untested |
| Windows on ARM, incl. a Pi 3/4/5 | `GpioClx` + **rhproxy** → WinRT `Windows.Devices.Gpio` | not supported — a second backend |
| FreeBSD, NetBSD | `/dev/gpiocN`, a different ioctl set | not supported — a second backend |
| macOS | no Mac has GPIO pins | out of scope |

Windows deserves a word, because "Windows has no GPIO" is wrong. Windows on ARM
runs on a Raspberry Pi 3/4/5, and it is the same silicon — the pins are
physically there. What Windows does not do is expose them as a character device:
GPIO arrives through the `GpioClx` driver and **rhproxy**, surfaced to user mode
as the WinRT `Windows.Devices.Gpio` API (the thing .NET's `System.Device.Gpio`
wraps on that platform). So Windows is a **second backend behind the same public
types**, not a port of this one — and the same is true of the BSDs, whose
`/dev/gpiocN` speaks its own ioctls.

None of that is planned work. It is why the package is called `gpio` rather than
`linux_gpio`, why `ioctl` and file descriptors stay out of the public API, and
why the Linux-specific entry point is a single named constructor
(`GpioChip.byPath`) rather than the shape of the whole library.

macOS is the one genuine "no": no Mac has GPIO pins, and macOS does not run on a
Pi. Reaching pins from a Mac means a USB bridge (FT232H, MCP2221), which is a
device driver rather than an OS backend.

## Running the tests

```sh
dart test                  # 102 tests, no hardware needed
dart test -t integration   # real ioctls against the kernel's gpio-sim
```

The default suite runs against an in-memory model of the character device, so
it passes on any machine.

The `integration` suite is the one that talks to a real `/dev/gpiochipN`, via
the kernel's own `gpio-sim` module — the same thing libgpiod's test suite uses.
It needs **root** and a kernel with `CONFIG_GPIO_SIM`. On GitHub's hosted
runners the driver ships in `linux-modules-extra-$(uname -r)`, which the runner
image does not install by default; CI installs it and the suite runs on every
build. A stock Debian, Ubuntu or Raspberry Pi OS kernel has it already.

**What is still unverified:** every test, including the `gpio-sim` ones, runs
against a *simulated* chip. This package has not yet driven a physical pin on
real silicon — no measured press-to-event latency, no real debounce on a bouncy
switch. Treat it as pre-release until that happens.

## Licence

MIT. The bindings are generated from the kernel's own `<linux/gpio.h>`, which
carries the `Linux-syscall-note` exception precisely so userspace programs under
any licence may use those definitions. libgpiod (LGPL) is deliberately not a
source for any part of this package.
