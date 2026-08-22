/// Fixed-width C name fields, shared by everything that touches one.
///
/// These live apart from the chip layer because the line-info reader needs
/// them on its own isolate, and importing the chip there would be circular.
library;

import 'dart:convert';
import 'dart:ffi' as ffi;

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
