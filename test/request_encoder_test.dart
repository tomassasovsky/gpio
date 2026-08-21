@TestOn('linux')
library;

import 'package:gpio/gpio.dart';
import 'package:gpio/gpio_testing.dart';
import 'package:gpio/src/ffi/gpio_uapi.dart';
import 'package:gpio/src/line_config.dart';
import 'package:gpio/src/request_encoder.dart';
import 'package:test/test.dart';

const _attrFlags = 1;
const _attrOutputValues = 2;
const _attrDebounce = 3;

void main() {
  group('flag translation', () {
    test('an input with a pull-up and both edges', () {
      final flags = const LineConfig.input(
        0,
        bias: Bias.pullUp,
        edge: Edge.both,
      ).flags;
      expect(flags & LineFlag.input, isNonZero);
      expect(flags & LineFlag.biasPullUp, isNonZero);
      expect(flags & LineFlag.edgeRising, isNonZero);
      expect(flags & LineFlag.edgeFalling, isNonZero);
      expect(flags & LineFlag.output, isZero);
    });

    test('edge flags are ignored on an output', () {
      // Asking the kernel for edge detection on an output earns EINVAL, so the
      // combination must never be encoded in the first place.
      final flags = const LineConfig.output(0, drive: Drive.openDrain).flags;
      expect(flags & LineFlag.edgeRising, isZero);
      expect(flags & LineFlag.edgeFalling, isZero);
      expect(flags & LineFlag.openDrain, isNonZero);
    });

    test('drive flags are ignored on an input', () {
      final flags = const LineConfig.input(0, edge: Edge.rising).flags;
      expect(flags & LineFlag.openDrain, isZero);
      expect(flags & LineFlag.openSource, isZero);
    });

    test('Bias.asIs sets no bias bit at all', () {
      final flags = const LineConfig.input(0).flags;
      const anyBias =
          LineFlag.biasPullUp | LineFlag.biasPullDown | LineFlag.biasDisabled;
      expect(flags & anyBias, isZero);
    });
  });

  group('attribute packing', () {
    test('uniform lines need no flag attribute at all', () {
      final encoder = RequestEncoder(
        const [LineConfig.input(0), LineConfig.input(1), LineConfig.input(2)],
        EventClock.monotonic,
      );
      expect(encoder.attributes.where((a) => a.id == _attrFlags), isEmpty);
      expect(encoder.defaultFlags & LineFlag.input, isNonZero);
    });

    test('the majority configuration becomes the default', () {
      // Three inputs and one output: the default should be the input flags, so
      // only one override is needed rather than three.
      final encoder = RequestEncoder(
        const [
          LineConfig.input(0),
          LineConfig.input(1),
          LineConfig.input(2),
          LineConfig.output(3),
        ],
        EventClock.monotonic,
      );
      expect(encoder.defaultFlags & LineFlag.input, isNonZero);
      final flagAttrs =
          encoder.attributes.where((a) => a.id == _attrFlags).toList();
      expect(flagAttrs, hasLength(1));
      expect(flagAttrs.single.mask, 1 << 3);
    });

    test('a flags attribute carries the event clock too', () {
      // A flags attribute REPLACES the defaults for the lines it covers, so a
      // request-wide bit left only in the defaults would be silently dropped
      // for exactly those lines.
      final encoder = RequestEncoder(
        const [
          LineConfig.input(0),
          LineConfig.input(1),
          LineConfig.output(2),
        ],
        EventClock.realtime,
      );
      expect(encoder.defaultFlags & LineFlag.eventClockRealtime, isNonZero);
      for (final attr in encoder.attributes.where((a) => a.id == _attrFlags)) {
        expect(
          attr.value & LineFlag.eventClockRealtime,
          isNonZero,
          reason: 'override dropped the request-wide event clock',
        );
      }
    });

    test('output values ride in a single attribute', () {
      final encoder = RequestEncoder(
        const [
          LineConfig.output(0, initialValue: true),
          LineConfig.output(1),
          LineConfig.output(2, initialValue: true),
        ],
        EventClock.monotonic,
      );
      final values =
          encoder.attributes.singleWhere((a) => a.id == _attrOutputValues);
      expect(values.mask, 0x7);
      expect(values.value, 0x5); // lines 0 and 2 high
    });

    test('lines sharing a debounce period share one attribute', () {
      final encoder = RequestEncoder(
        const [
          LineConfig.input(
            0,
            edge: Edge.both,
            debounce: Duration(
              milliseconds: 5,
            ),
          ),
          LineConfig.input(
            1,
            edge: Edge.both,
            debounce: Duration(
              milliseconds: 5,
            ),
          ),
          LineConfig.input(
            2,
            edge: Edge.both,
            debounce: Duration(
              milliseconds: 20,
            ),
          ),
        ],
        EventClock.monotonic,
      );
      final debounces =
          encoder.attributes.where((a) => a.id == _attrDebounce).toList();
      expect(debounces, hasLength(2));
      expect(
        debounces.firstWhere((a) => a.value == 5000).mask,
        0x3,
        reason: 'lines 0 and 1 share the 5 ms period',
      );
      expect(debounces.firstWhere((a) => a.value == 20000).mask, 0x4);
    });

    test('debounce is encoded even without edge detection', () {
      // The kernel's debouncer feeds plain reads as well as events --
      // linereq_get_values returns debounced_value() whenever sw_debounced is
      // set -- so dropping it for a polled input would quietly discard a
      // debounce the caller asked for.
      final encoder = RequestEncoder(
        const [LineConfig.input(0, debounce: Duration(milliseconds: 5))],
        EventClock.monotonic,
      );
      final debounce =
          encoder.attributes.singleWhere((a) => a.id == _attrDebounce);
      expect(debounce.value, 5000);
      expect(debounce.mask, 0x1);
    });

    test('debounce is not encoded for an output', () {
      final encoder = RequestEncoder(
        const [LineConfig.output(0)],
        EventClock.monotonic,
      );
      expect(encoder.attributes.where((a) => a.id == _attrDebounce), isEmpty);
    });

    test('a debounce period too large for the kernel u32 is rejected', () {
      expect(
        () => RequestEncoder(
          const [
            LineConfig.input(0, debounce: Duration(minutes: 72)),
          ],
          EventClock.monotonic,
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('71.6')),
        ),
      );
    });

    test('exceeding the kernel attribute limit is a clear error', () {
      // Eleven distinct debounce periods needs eleven attributes; ten is the
      // hard ceiling.
      final lines = [
        for (var i = 0; i < 11; i++)
          LineConfig.input(
            i,
            edge: Edge.both,
            debounce: Duration(microseconds: 100 * (i + 1)),
          ),
      ];
      expect(
        () => RequestEncoder(lines, EventClock.monotonic),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('$GPIO_V2_LINE_NUM_ATTRS_MAX'),
              contains('separate requests'),
            ),
          ),
        ),
      );
    });
  });

  group('end to end through the fake kernel', () {
    test('a debounced pull-up input arrives configured as asked', () {
      final kernel = FakeKernel.single();
      final chip = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
      addTearDown(chip.close);

      final request = chip.request(
        consumer: 'looper',
        lines: [
          const LineConfig.input(
            2,
            bias: Bias.pullUp,
            edge: Edge.both,
            debounce: Duration(milliseconds: 5),
            activeLow: true,
          ),
        ],
      );
      addTearDown(request.close);

      final info = chip.lineInfo(2);
      expect(info.consumer, 'looper');
      expect(info.used, isTrue);
      expect(info.direction, LineDirection.input);
      expect(info.bias, Bias.pullUp);
      expect(info.edge, Edge.both);
      expect(info.activeLow, isTrue);
      expect(info.debouncePeriod, const Duration(milliseconds: 5));
    });

    test('a request of 64 lines is accepted; 65 is rejected', () {
      final kernel = FakeKernel.single(lineCount: 70);
      final chip = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
      addTearDown(chip.close);

      final ok = chip.request(
        lines: [for (var i = 0; i < 64; i++) LineConfig.input(i)],
      );
      addTearDown(ok.close);
      expect(ok.offsets, hasLength(64));

      expect(
        () => chip.request(
          lines: [for (var i = 0; i < 65; i++) LineConfig.input(i)],
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('64')),
        ),
      );
    });
  });
}
