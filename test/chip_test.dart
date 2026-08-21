@TestOn('linux')
library;

import 'package:gpio/gpio.dart';
import 'package:gpio/gpio_testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeKernel kernel;

  setUp(() {
    kernel = FakeKernel([
      FakeChip(
        name: 'gpiochip0',
        label: 'some-other-controller',
        lineCount: 4,
      ),
      FakeChip(
        name: 'gpiochip4',
        label: 'pinctrl-rp1',
        lineCount: 28,
        lineNames: {17: 'GPIO17', 27: 'GPIO27'},
      ),
    ]);
  });

  group('discovery', () {
    test('byPath reads the chip info', () {
      final chip = GpioChip.byPath('/dev/gpiochip4', syscalls: kernel);
      addTearDown(chip.close);
      expect(chip.info.name, 'gpiochip4');
      expect(chip.info.label, 'pinctrl-rp1');
      expect(chip.info.lineCount, 28);
    });

    test('byLabel finds the chip wherever it was enumerated', () {
      // The point of the whole API: on a Pi 5 the header is gpiochip4 on older
      // kernels and gpiochip0 on newer ones, but the label never moves.
      final chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
      addTearDown(chip.close);
      expect(chip.info.label, 'pinctrl-rp1');
      expect(chip.info.name, 'gpiochip4');
    });

    test('byLabel names what it did find when it fails', () {
      expect(
        () => GpioChip.byLabel('pinctrl-bcm2711', syscalls: kernel),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('pinctrl-rp1'), contains('some-other-controller')),
          ),
        ),
      );
    });

    test('byLabel leaves no descriptor behind when it fails', () {
      expect(
        () => GpioChip.byLabel('nope', syscalls: kernel),
        throwsStateError,
      );
      expect(kernel.openDescriptors, 0);
    });

    test('a missing device reports ENOENT with a hint about numbering', () {
      expect(
        () => GpioChip.byPath('/dev/gpiochip99', syscalls: kernel),
        throwsA(
          isA<GpioException>()
              .having((e) => e.errno, 'errno', 2)
              .having((e) => e.message, 'message', contains('by label')),
        ),
      );
      expect(kernel.openDescriptors, 0);
    });

    test('findLine resolves a device-tree name to an offset', () {
      final chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
      addTearDown(chip.close);
      expect(chip.findLine('GPIO17'), 17);
      expect(chip.findLine('GPIO27'), 27);
    });

    test('findLine returns null for a name the chip does not have', () {
      final chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
      addTearDown(chip.close);
      expect(chip.findLine('GPIO99'), isNull);
    });
  });

  group('bounds', () {
    late GpioChip chip;

    setUp(() {
      chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
      addTearDown(chip.close);
    });

    test('an offset past the end of the chip is rejected before the ioctl', () {
      expect(() => chip.lineInfo(28), throwsRangeError);
      expect(() => chip.lineInfo(-1), throwsRangeError);
    });

    test('an empty request is rejected', () {
      expect(
        () => chip.request(lines: []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a duplicated offset in one request is rejected', () {
      expect(
        () => chip.request(
          lines: [const LineConfig.input(1), const LineConfig.output(1)],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('more than once'),
          ),
        ),
      );
    });

    test('using a closed chip is a StateError, not a bad descriptor', () {
      chip.close();
      expect(() => chip.lineInfo(0), throwsStateError);
    });

    test('close is idempotent', () {
      chip
        ..close()
        ..close();
      expect(chip.isClosed, isTrue);
    });
  });

  group('ownership', () {
    test(
        'a second request for a held line reports EBUSY and names the '
        'consumer holding it', () {
      final chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
      addTearDown(chip.close);

      final first = chip.request(
        consumer: 'looper',
        lines: [const LineConfig.input(3)],
      );
      addTearDown(first.close);

      expect(
        () =>
            chip.request(consumer: 'other', lines: [const LineConfig.input(3)]),
        throwsA(
          isA<GpioException>()
              .having((e) => e.isBusy, 'isBusy', isTrue)
              .having((e) => e.message, 'message', contains('looper')),
        ),
      );
    });

    test('closing a request releases its lines', () async {
      final chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
      addTearDown(chip.close);

      await chip.request(
        consumer: 'first',
        lines: [const LineConfig.input(3)],
      ).close();
      final second = chip.request(
        consumer: 'second',
        lines: [const LineConfig.input(3)],
      );
      addTearDown(second.close);
      expect(second.offsets, [3]);
    });

    test('a request outlives the chip it came from', () {
      // The kernel ties ownership to the request descriptor, not the chip's.
      final chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
      final request = chip.request(lines: [const LineConfig.output(2)]);
      addTearDown(request.close);
      chip.close();
      expect(() => request.setValue(2, value: true), returnsNormally);
    });
  });

  group('errno messages name the right cause', () {
    test('ENOTTY does not blame the kernel version', () {
      // The VFS returns ENOTTY when the file has no ioctl handler -- it is not
      // a gpiochip. A kernel too old for v2 does NOT land here: gpio_ioctl's
      // `default:` branch answers EINVAL (gpiolib-cdev.c). An earlier version
      // of this message promised "needs Linux 5.10 or newer" for a case that
      // can never produce it.
      final e = GpioException('GPIO_V2_GET_LINE', 25, path: '/dev/null');
      expect(e.message, contains('not a GPIO character device'));
      expect(e.message, isNot(contains('5.10')));
    });

    test('EINVAL is where the too-old-kernel case actually surfaces', () {
      final e = GpioException('GPIO_V2_GET_LINE', 22, path: '/dev/gpiochip0');
      expect(e.message, contains('5.10'));
      expect(e.message, contains('v2 GPIO interface'));
    });

    test('EACCES gives the remedy, not just the refusal', () {
      final e = GpioException('open', 13, path: '/dev/gpiochip0');
      expect(e.isPermissionDenied, isTrue);
      expect(e.message, contains('udev'));
      expect(e.message, contains('gpio group'));
    });
  });

  test('only v2 ioctls are ever issued', () {
    final chip = GpioChip.byLabel('pinctrl-rp1', syscalls: kernel);
    addTearDown(chip.close);
    final request = chip.request(lines: [const LineConfig.input(1)]);
    addTearDown(request.close);
    request.getValues();

    // The deprecated v1 request/event ioctls, which this package must never
    // fall back to.
    const v1GetLineHandle = 0xc16cb403;
    const v1GetLineEvent = 0xc030b404;
    expect(kernel.ioctlLog, isNot(contains(v1GetLineHandle)));
    expect(kernel.ioctlLog, isNot(contains(v1GetLineEvent)));
  });
}
