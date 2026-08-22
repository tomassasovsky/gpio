@TestOn('linux')
library;

import 'dart:ffi' as ffi;

import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/ffi/ioctl.dart';
import 'package:test/test.dart';

/// The GPIO uAPI is deliberately fixed-width: every field is a `__u8`/`__u32`/
/// `__u64` or a fixed char array, and the 64-bit members are 8-byte aligned on
/// every ABI Dart targets. So these sizes are the same on 32-bit ARM as on
/// arm64 and x64 — verified directly against `<linux/gpio.h>` under both
/// `gcc -m32` and `gcc -m64`.
///
/// This test is what makes that a *checked* property rather than an assumption.
///
/// It checks **size only**, which is deliberately not the whole story: the
/// `_IOC` request number encodes `sizeof()`, so a size-preserving drift would
/// slip through here with an identical request number. Field offsets are pinned
/// separately, on the Dart side in `struct_layout_test.dart` and on the C side
/// in `tool/check_abi_32bit.sh`.
void main() {
  group('struct layout matches the kernel uAPI', () {
    // Values read from <linux/gpio.h> on Linux 6.x.
    const expected = <String, int>{
      'gpiochip_info': 68,
      'gpio_v2_line_attribute': 16,
      'gpio_v2_line_config_attribute': 24,
      'gpio_v2_line_config': 272,
      'gpio_v2_line_request': 592,
      'gpio_v2_line_info': 256,
      'gpio_v2_line_values': 16,
      'gpio_v2_line_event': 48,
      // Read via raw read(2) rather than as an ioctl argument, so unlike every
      // struct above it has no _IOC/ENOTTY tripwire behind it. Drift here would
      // silently desync the line-info watch stream, which makes asserting it
      // here more load-bearing, not less.
      'gpio_v2_line_info_changed': 288,
    };

    test('gpiochip_info', () {
      expect(ffi.sizeOf<gpiochip_info>(), expected['gpiochip_info']);
    });

    test('gpio_v2_line_attribute', () {
      expect(
        ffi.sizeOf<gpio_v2_line_attribute>(),
        expected['gpio_v2_line_attribute'],
      );
    });

    test('gpio_v2_line_config_attribute', () {
      expect(
        ffi.sizeOf<gpio_v2_line_config_attribute>(),
        expected['gpio_v2_line_config_attribute'],
      );
    });

    test('gpio_v2_line_config', () {
      expect(
        ffi.sizeOf<gpio_v2_line_config>(),
        expected['gpio_v2_line_config'],
      );
    });

    test('gpio_v2_line_request', () {
      expect(
        ffi.sizeOf<gpio_v2_line_request>(),
        expected['gpio_v2_line_request'],
      );
    });

    test('gpio_v2_line_info', () {
      expect(ffi.sizeOf<gpio_v2_line_info>(), expected['gpio_v2_line_info']);
    });

    test('gpio_v2_line_values', () {
      expect(
        ffi.sizeOf<gpio_v2_line_values>(),
        expected['gpio_v2_line_values'],
      );
    });

    test('gpio_v2_line_event', () {
      expect(ffi.sizeOf<gpio_v2_line_event>(), expected['gpio_v2_line_event']);
    });

    test('gpio_v2_line_info_changed', () {
      expect(
        ffi.sizeOf<gpio_v2_line_info_changed>(),
        expected['gpio_v2_line_info_changed'],
      );
    });
  });

  group('uAPI constants match the kernel header', () {
    test('array bounds', () {
      expect(GPIO_V2_LINES_MAX, 64);
      expect(GPIO_V2_LINE_NUM_ATTRS_MAX, 10);
      expect(GPIO_MAX_NAME_SIZE, 32);
    });
  });

  group('computed ioctl request numbers', () {
    // Expanded from the _IOC macros in <linux/gpio.h> by the C preprocessor.
    // Identical under -m32 and -m64: the encoding carries sizeof(), and every
    // one of these structs is the same size on both.
    test('match the values the kernel expects', () {
      expect(GpioIoctl.getChipInfo, 0x8044b401);
      expect(GpioIoctl.v2GetLineInfo, 0xc100b405);
      expect(GpioIoctl.v2WatchLineInfo, 0xc100b406);
      expect(GpioIoctl.v2GetLine, 0xc250b407);
      expect(GpioIoctl.v2LineSetConfig, 0xc110b40d);
      expect(GpioIoctl.v2LineGetValues, 0xc010b40e);
      expect(GpioIoctl.v2LineSetValues, 0xc010b40f);
      // The only request number derived from a scalar rather than a struct,
      // and so the only one a struct-size assertion would not have caught.
      expect(GpioIoctl.unwatchLineInfo, 0xc004b40c);
    });

    test('_IO encodes a no-argument request', () {
      // _IO(0xB4, 0x01) — direction none, size zero.
      expect(Ioc.io(0xB4, 0x01), 0x0000b401);
    });

    test('direction bits distinguish read, write and read-write', () {
      final r = Ioc.ior(0xB4, 0x0E, ffi.sizeOf<gpio_v2_line_values>());
      final w = Ioc.iow(0xB4, 0x0E, ffi.sizeOf<gpio_v2_line_values>());
      final rw = Ioc.iowr(0xB4, 0x0E, ffi.sizeOf<gpio_v2_line_values>());
      expect(r, isNot(w));
      expect(rw, isNot(r));
      expect(rw, isNot(w));
      // The low 16 bits (type + nr) are shared; only direction differs.
      expect(r & 0xffff, w & 0xffff);
      expect(r & 0xffff, rw & 0xffff);
    });
  });
}
