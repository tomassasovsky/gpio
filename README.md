# gpio

Linux GPIO from pure Dart, over the `/dev/gpiochip*` character device using the
**v2 userspace ABI**.

No native library. No bundled binaries. No `apt install` step. Just `dart:ffi`
and the libc that is already in your process.

> **Status: in development.** The ABI layer is in place and verified; the public
> API is landing next. Not yet published to pub.dev.

## Why another GPIO package

Because the v2 ABI carries three things v1 does not, and every existing Dart
option gives up at least one of them:

- **Kernel-side debounce**, so contact bounce is filtered below userspace
  instead of by a timer you wrote.
- **Event sequence numbers**, so when the kernel's buffer overflows and edges
  are dropped, you find out. Every other Dart package silently loses them.
- **A selectable event clock**, so timestamps mean something specific.

Edge events arrive as a `Stream`, timestamped by the kernel at the interrupt —
so scheduling affects when you *see* an event, never what time it says.

## Requirements

- Linux 5.10 or newer (when the v2 ABI landed). There is no v1 fallback, by
  design — you cannot silently end up on the deprecated ABI.
- Access to `/dev/gpiochip*`. Root works; a udev rule is better:

  ```
  # /etc/udev/rules.d/60-gpio.rules
  SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
  ```

  then add your user to the `gpio` group and re-login.

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

## Licence

MIT. The bindings are generated from the kernel's own `<linux/gpio.h>`, which
carries the `Linux-syscall-note` exception precisely so userspace programs under
any licence may use those definitions. libgpiod (LGPL) is deliberately not a
source for any part of this package.
