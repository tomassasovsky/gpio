@TestOn('linux')
library;

import 'package:gpio/gpio.dart';
import 'package:gpio/gpio_testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeKernel kernel;
  late FakeChip fake;
  late GpioChip chip;

  setUp(() {
    fake = FakeChip(name: 'gpiochip0', label: 'fake', lineCount: 16);
    kernel = FakeKernel([fake]);
    chip = GpioChip.byLabel('fake', syscalls: kernel);
    addTearDown(chip.close);
  });

  group('reading', () {
    test('reads every held line from one sample', () {
      fake.setLevels({0: true, 1: false, 2: true});
      final request = chip.request(
        lines: [
          const LineConfig.input(0),
          const LineConfig.input(1),
          const LineConfig.input(2),
        ],
      );
      addTearDown(request.close);

      expect(request.getValues(), {0: true, 1: false, 2: true});
    });

    test('activeLow inverts the logical value, not the pin', () {
      fake.setLevel(5, value: false); // pin pulled to ground
      final request = chip.request(
        lines: [const LineConfig.input(5, bias: Bias.pullUp, activeLow: true)],
      );
      addTearDown(request.close);

      // A stomped switch shorts to ground; active-low makes that `true`.
      expect(request.getValue(5), isTrue);

      fake.setLevel(5, value: true);
      expect(request.getValue(5), isFalse);
    });

    test('values are keyed by line offset, not request position', () {
      fake.setLevels({9: true, 4: false});
      final request = chip.request(
        lines: [const LineConfig.input(9), const LineConfig.input(4)],
      );
      addTearDown(request.close);

      expect(request.getValues(), {9: true, 4: false});
    });

    test('reading a line the request does not hold is an ArgumentError', () {
      final request = chip.request(lines: [const LineConfig.input(1)]);
      addTearDown(request.close);
      expect(() => request.getValue(2), throwsA(isA<ArgumentError>()));
    });
  });

  group('writing', () {
    test('the initial value is applied by the claiming ioctl itself', () {
      // Not a separate write afterwards: the line must never pass through an
      // undefined state on its way to the value that was asked for.
      final request = chip.request(
        lines: [const LineConfig.output(7, initialValue: true)],
      );
      addTearDown(request.close);
      expect(fake.level(7), isTrue);
    });

    test('an active-low output inverts what reaches the pin', () {
      final request = chip.request(
        lines: [
          const LineConfig.output(7, initialValue: true, activeLow: true),
        ],
      );
      addTearDown(request.close);
      expect(fake.level(7), isFalse);
    });

    test('setValues leaves unnamed lines alone', () {
      final request = chip.request(
        lines: [
          const LineConfig.output(1, initialValue: true),
          const LineConfig.output(2),
          const LineConfig.output(3, initialValue: true),
        ],
      );
      addTearDown(request.close);

      request.setValues({2: true});

      expect(fake.level(1), isTrue, reason: 'must not be glitched');
      expect(fake.level(2), isTrue);
      expect(fake.level(3), isTrue, reason: 'must not be glitched');
    });

    test('driving an input is refused locally, with a useful message', () {
      // The kernel answers EPERM, which reads as a permissions problem and
      // sends people hunting for udev rules that are not the issue.
      final request = chip.request(lines: [const LineConfig.input(1)]);
      addTearDown(request.close);
      expect(
        () => request.setValue(1, value: true),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('as an input')),
        ),
      );
    });

    test('a partially invalid write drives nothing at all', () {
      final request = chip.request(
        lines: [const LineConfig.output(1), const LineConfig.input(2)],
      );
      addTearDown(request.close);

      expect(
        () => request.setValues({1: true, 2: true}),
        throwsA(isA<ArgumentError>()),
      );
      expect(fake.level(1), isFalse, reason: 'must not be half-applied');
    });

    test('a mixed request reads inputs and drives outputs together', () {
      fake.setLevel(0, value: true);
      final request = chip.request(
        lines: [
          const LineConfig.input(0, bias: Bias.pullUp),
          const LineConfig.output(1),
        ],
      );
      addTearDown(request.close);

      expect(request.getValue(0), isTrue);
      request.setValue(1, value: true);
      expect(fake.level(1), isTrue);
    });
  });

  group('reconfigure', () {
    test('keeps the lines claimed across the change', () {
      final request = chip.request(
        consumer: 'holder',
        lines: [const LineConfig.input(4)],
      );
      addTearDown(request.close);

      request.reconfigure([const LineConfig.output(4, initialValue: true)]);

      expect(fake.level(4), isTrue);
      // Still ours throughout — nothing could have slipped in.
      expect(
        () =>
            chip.request(consumer: 'thief', lines: [const LineConfig.input(4)]),
        throwsA(isA<GpioException>().having((e) => e.isBusy, 'isBusy', true)),
      );
    });

    test('preserves the event clock the request was made with', () {
      // A `monotonic` default on reconfigure would silently revert this.
      final request = chip.request(
        lines: [const LineConfig.input(4)],
        eventClock: EventClock.realtime,
      );
      addTearDown(request.close);
      expect(request.eventClock, EventClock.realtime);

      request.reconfigure([const LineConfig.input(4, edge: Edge.both)]);
      expect(request.eventClock, EventClock.realtime);
    });

    test('refuses a set of offsets that is not the one we hold', () {
      final request = chip.request(lines: [const LineConfig.input(4)]);
      addTearDown(request.close);
      expect(
        () => request.reconfigure([const LineConfig.input(5)]),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.message, 'message', contains('exactly')),
        ),
      );
    });
  });

  group('closed requests', () {
    test('reject further use', () async {
      final request = chip.request(lines: [const LineConfig.output(1)]);
      await request.close();
      expect(request.getValues, throwsStateError);
      expect(() => request.setValue(1, value: true), throwsStateError);
      expect(() => request.fd, throwsStateError);
    });

    test('close is idempotent and leaks nothing', () async {
      final request = chip.request(lines: [const LineConfig.output(1)]);
      await request.close();
      await request.close();
      expect(kernel.openDescriptors, 1, reason: 'only the chip remains open');
    });
  });
}
