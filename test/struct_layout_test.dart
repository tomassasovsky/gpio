@TestOn('linux')
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:test/test.dart';

/// Sizes prove less than they appear to.
///
/// The `_IOC` request number encodes `sizeof()`, so a **size-preserving**
/// change — a future kernel spending part of a reserved `padding[]`, or two
/// same-width fields swapping — produces an identical request number, passes
/// every size assertion, and then silently reads the wrong field.
/// `tool/check_abi_32bit.sh` pins the offsets on the C side; this pins them on
/// the *Dart* side, which is the half that could disagree.
///
/// The technique: write a distinct sentinel into one field of a zeroed struct,
/// then find which bytes changed. Where the sentinel lands *is* the offset that
/// Dart will use when it talks to the kernel.
void main() {
  /// Byte offset at which [write] deposits a non-zero value, and its
  /// width in bytes.
  ({int offset, int width}) probe<T extends ffi.Struct>(
    int size,
    void Function(ffi.Pointer<T>) write,
  ) {
    final mem = calloc<ffi.Uint8>(size);
    try {
      write(mem.cast<T>());
      final bytes = mem.asTypedList(size);
      final first = bytes.indexWhere((b) => b != 0);
      expect(
        first,
        isNot(-1),
        reason: 'sentinel never landed anywhere in the struct',
      );
      var last = first;
      while (last + 1 < size && bytes[last + 1] != 0) {
        last++;
      }
      return (offset: first, width: last - first + 1);
    } finally {
      calloc.free(mem);
    }
  }

  group('gpio_v2_line_request field offsets', () {
    final size = ffi.sizeOf<gpio_v2_line_request>();

    test('num_lines', () {
      final p =
          probe<gpio_v2_line_request>(size, (s) => s.ref.num_lines = 0xFF);
      expect(p.offset, 560);
    });

    test('event_buffer_size', () {
      final p = probe<gpio_v2_line_request>(
        size,
        (s) => s.ref.event_buffer_size = 0xFF,
      );
      expect(p.offset, 564);
    });

    test('fd', () {
      final p = probe<gpio_v2_line_request>(size, (s) => s.ref.fd = 0x7F);
      expect(p.offset, 588);
    });

    test('consumer is a 32-byte name field', () {
      final p = probe<gpio_v2_line_request>(
        size,
        (s) => s.ref.consumer[0] = 0x41,
      );
      expect(p.offset, 256);
    });

    test('config begins where the offsets array ends', () {
      final p = probe<gpio_v2_line_request>(
        size,
        (s) => s.ref.config.flags = 0xFF,
      );
      expect(p.offset, 288);
    });
  });

  group('gpio_v2_line_event field offsets', () {
    final size = ffi.sizeOf<gpio_v2_line_event>();

    test('timestamp_ns leads the struct', () {
      final p =
          probe<gpio_v2_line_event>(size, (s) => s.ref.timestamp_ns = 0xFF);
      expect(p.offset, 0);
    });

    test('id', () {
      final p = probe<gpio_v2_line_event>(size, (s) => s.ref.id = 0xFF);
      expect(p.offset, 8);
    });

    test('offset', () {
      final p = probe<gpio_v2_line_event>(size, (s) => s.ref.offset = 0xFF);
      expect(p.offset, 12);
    });

    test('seqno', () {
      final p = probe<gpio_v2_line_event>(size, (s) => s.ref.seqno = 0xFF);
      expect(p.offset, 16);
    });

    test('line_seqno — the field that makes dropped edges detectable', () {
      final p = probe<gpio_v2_line_event>(size, (s) => s.ref.line_seqno = 0xFF);
      expect(p.offset, 20);
    });
  });

  group('gpio_v2_line_values field offsets', () {
    final size = ffi.sizeOf<gpio_v2_line_values>();

    test('bits then mask, both 64-bit', () {
      final bits = probe<gpio_v2_line_values>(size, (s) => s.ref.bits = ~0);
      expect(bits.offset, 0);
      expect(bits.width, 8);

      final mask = probe<gpio_v2_line_values>(size, (s) => s.ref.mask = ~0);
      expect(mask.offset, 8);
      expect(mask.width, 8);
    });
  });

  group('endianness', () {
    test('Dart writes the struct in host byte order', () {
      // If Dart and the kernel disagreed on byte order every multi-byte field
      // would be silently transposed, which no offset check would catch.
      final mem = calloc<ffi.Uint8>(ffi.sizeOf<gpio_v2_line_values>());
      try {
        // Assembled rather than written as a literal: the analyzer rejects
        // 64-bit literals JavaScript could not represent, and a dart:ffi-only
        // package will never see a JS backend.
        const pattern = (0x01020304 << 32) | 0x05060708;
        mem.cast<gpio_v2_line_values>().ref.bits = pattern;
        final host =
            ByteData.sublistView(mem.asTypedList(8)).getUint64(0, Endian.host);
        expect(host, pattern);
      } finally {
        calloc.free(mem);
      }
    });
  });
}
