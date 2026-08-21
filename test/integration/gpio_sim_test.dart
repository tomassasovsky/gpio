@Tags(['integration'])
@TestOn('linux')
library;

import 'package:gpio/gpio.dart';
import 'package:test/test.dart';

import 'gpio_sim.dart';

/// Exercises the real ioctl path against a kernel-provided simulated chip.
///
/// Everything else in this suite runs against `FakeKernel`, which is a model of
/// the kernel written by the same hand as the code it checks. These tests are
/// the ones that would catch a shared misunderstanding: real `/dev/gpiochipN`,
/// real `GPIO_V2_*` ioctls, real gpiolib.
void main() {
  if (!GpioSim.isAvailable) {
    // Skipped, never failed: most CI runners and dev machines cannot do this,
    // and the fake-kernel suite is what actually gates the build.
    test('gpio-sim integration', () {}, skip: GpioSim.unavailableReason);
    return;
  }

  late GpioSim sim;

  setUp(() {
    sim = GpioSim.create(name: 'dartgpio', label: 'dart-gpio-test');
    addTearDown(sim.destroy);
  });

  test('finds the simulated chip by its label', () {
    final chip = GpioChip.byLabel('dart-gpio-test');
    addTearDown(chip.close);
    expect(chip.info.label, 'dart-gpio-test');
    expect(chip.info.lineCount, 8);
  });

  test('reads a line the simulator is driving', () {
    final chip = GpioChip.byPath(sim.chipPath);
    addTearDown(chip.close);
    final request = chip.request(lines: [const LineConfig.input(0)]);
    addTearDown(request.close);

    sim.setPull(0, high: true);
    expect(request.getValue(0), isTrue);

    sim.setPull(0, high: false);
    expect(request.getValue(0), isFalse);
  });

  test('drives an output the simulator can see', () {
    final chip = GpioChip.byPath(sim.chipPath);
    addTearDown(chip.close);
    final request = chip.request(
      lines: [const LineConfig.output(1, initialValue: true)],
    );
    addTearDown(request.close);

    expect(sim.value(1), isTrue, reason: 'initial value applied at request');
    request.setValue(1, value: false);
    expect(sim.value(1), isFalse);
  });

  test('the real kernel rejects a second claim on a held line', () {
    final chip = GpioChip.byPath(sim.chipPath);
    addTearDown(chip.close);
    final first = chip.request(
      consumer: 'holder',
      lines: [const LineConfig.input(2)],
    );
    addTearDown(first.close);

    expect(
      () => chip.request(consumer: 'other', lines: [const LineConfig.input(2)]),
      throwsA(isA<GpioException>().having((e) => e.isBusy, 'isBusy', isTrue)),
    );
  });

  test('delivers a real edge event with a real kernel timestamp', () async {
    final chip = GpioChip.byPath(sim.chipPath);
    addTearDown(chip.close);
    final request = chip.request(
      lines: [const LineConfig.input(3, edge: Edge.both)],
    );
    addTearDown(request.close);

    final events = <LineEvent>[];
    final subscription = request.events.listen(events.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    sim.setPull(3, high: true);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(events, isNotEmpty);
    final edge = events.whereType<LineEdgeEvent>().first;
    expect(edge.offset, 3);
    expect(edge.edge, Edge.rising);
    expect(
      edge.timestampNs,
      greaterThan(0),
      reason: 'the kernel stamped this, not us',
    );
    await subscription.cancel();
  });

  test('kernel debounce is accepted and reported back', () {
    final chip = GpioChip.byPath(sim.chipPath);
    addTearDown(chip.close);
    final request = chip.request(
      lines: [
        const LineConfig.input(
          4,
          edge: Edge.both,
          debounce: Duration(milliseconds: 5),
        ),
      ],
    );
    addTearDown(request.close);

    expect(chip.lineInfo(4).debouncePeriod, const Duration(milliseconds: 5));
  });
}
