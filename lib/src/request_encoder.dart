import 'dart:ffi';

import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/line_config.dart';
import 'package:gpio/src/models.dart';

/// Packs a set of [LineConfig]s into `gpio_v2_line_config`.
///
/// The kernel's scheme is one set of default `flags` for the whole request,
/// plus up to [GPIO_V2_LINE_NUM_ATTRS_MAX] *attributes*, each carrying a value
/// and a bitmask of the lines it applies to. Three kinds of attribute exist:
/// a flags override, the initial output values, and a debounce period.
///
/// Two details are easy to get wrong and are handled here:
///
/// * A flags attribute **replaces** the default flags for the lines it covers
///   rather than adding to them, so request-wide bits — the event clock — must
///   be OR-ed into every override, not just into the defaults.
/// * Choosing the most common flag value as the default minimises overrides,
///   which matters because ten is a hard ceiling and a bank of mixed inputs and
///   outputs can reach it.
class RequestEncoder {
  /// Prepares the encoding for [lines] under [eventClock].
  factory RequestEncoder(List<LineConfig> lines, EventClock eventClock) {
    final clockBits = eventClockFlag(eventClock);

    // Group lines by their flag word so identical lines share one attribute.
    final byFlags = <int, int>{}; // flags -> bitmask of line indexes
    for (var i = 0; i < lines.length; i++) {
      final f = lines[i].flags | clockBits;
      byFlags[f] = (byFlags[f] ?? 0) | (1 << i);
    }

    // The most common flag word becomes the default, so it needs no attribute.
    var defaultFlags = byFlags.keys.first;
    var best = -1;
    for (final entry in byFlags.entries) {
      final count = _popCount(entry.value);
      if (count > best) {
        best = count;
        defaultFlags = entry.key;
      }
    }

    final attrs = <_Attr>[
      for (final entry in byFlags.entries)
        if (entry.key != defaultFlags) _Attr.flags(entry.key, entry.value),
    ];

    // One attribute carries every output's initial value.
    var outputMask = 0;
    var outputBits = 0;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].direction != LineDirection.output) continue;
      outputMask |= 1 << i;
      if (lines[i].initialValue) outputBits |= 1 << i;
    }
    if (outputMask != 0) {
      attrs.add(_Attr.outputValues(outputBits, outputMask));
    }

    // One attribute per distinct debounce period.
    //
    // Deliberately NOT gated on edge detection. The kernel's debouncer feeds
    // plain reads too -- linereq_get_values returns debounced_value() whenever
    // sw_debounced is set (gpiolib-cdev.c) -- so skipping it for a polled input
    // would silently discard a debounce the caller asked for.
    final byDebounce = <int, int>{};
    for (var i = 0; i < lines.length; i++) {
      final micros = lines[i].debounceMicros;
      if (micros <= 0) continue;
      if (lines[i].direction == LineDirection.output) continue;
      if (micros > _maxDebounceMicros) {
        throw ArgumentError.value(
          lines[i].debounce,
          'debounce',
          'the kernel carries the debounce period in a __u32 of microseconds, '
              'so it cannot exceed ${_maxDebounceMicros}us (about 71.6 '
              'minutes)',
        );
      }
      byDebounce[micros] = (byDebounce[micros] ?? 0) | (1 << i);
    }
    for (final entry in byDebounce.entries) {
      attrs.add(_Attr.debounce(entry.key, entry.value));
    }

    if (attrs.length > GPIO_V2_LINE_NUM_ATTRS_MAX) {
      throw ArgumentError(
        'This request needs ${attrs.length} line attributes but the kernel '
        'allows at most $GPIO_V2_LINE_NUM_ATTRS_MAX. Reduce the variety of '
        'line configurations, or split it into separate requests — note that '
        'values can only be read or written atomically within one request.',
      );
    }

    return RequestEncoder._(defaultFlags, attrs);
  }

  const RequestEncoder._(this.defaultFlags, this._attrs);

  /// `gpio_v2_line_attribute.debounce_period_us` is a `__u32`.
  static const int _maxDebounceMicros = 0xFFFFFFFF;

  /// `gpio_v2_line_config.flags`.
  final int defaultFlags;

  final List<_Attr> _attrs;

  /// How many attributes this encoding uses.
  int get attributeCount => _attrs.length;

  /// Writes the encoding into [config].
  void writeTo(gpio_v2_line_config config) {
    config
      ..flags = defaultFlags
      ..num_attrs = _attrs.length;
    for (var i = 0; i < _attrs.length; i++) {
      _attrs[i].writeTo(config.attrs[i]);
    }
  }

  /// The attributes, exposed for tests to assert against.
  List<({int id, int value, int mask})> get attributes =>
      [for (final a in _attrs) (id: a.id, value: a.value, mask: a.mask)];

  static int _popCount(int bits) {
    var n = 0;
    var v = bits;
    while (v != 0) {
      n += v & 1;
      // Unsigned shift: a request may hold 64 lines, and a mask with bit 63
      // set is a negative Dart int. Arithmetic `>>` would sign-extend forever.
      v >>>= 1;
    }
    return n;
  }
}

class _Attr {
  const _Attr(this.id, this.value, this.mask);

  factory _Attr.flags(int flags, int mask) => _Attr(
        gpio_v2_line_attr_id.GPIO_V2_LINE_ATTR_ID_FLAGS.value,
        flags,
        mask,
      );

  factory _Attr.outputValues(int bits, int mask) => _Attr(
        gpio_v2_line_attr_id.GPIO_V2_LINE_ATTR_ID_OUTPUT_VALUES.value,
        bits,
        mask,
      );

  factory _Attr.debounce(int micros, int mask) => _Attr(
        gpio_v2_line_attr_id.GPIO_V2_LINE_ATTR_ID_DEBOUNCE.value,
        micros,
        mask,
      );

  final int id;
  final int value;
  final int mask;

  void writeTo(gpio_v2_line_config_attribute slot) {
    slot.attr.id = id;
    switch (id) {
      case 1: // FLAGS
        slot.attr.unnamed.flags = value;
      case 2: // OUTPUT_VALUES
        slot.attr.unnamed.values = value;
      case 3: // DEBOUNCE
        slot.attr.unnamed.debounce_period_us = value;
    }
    slot.mask = mask;
  }
}
