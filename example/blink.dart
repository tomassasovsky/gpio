// Blinks an LED.
//
//   dart run example/blink.dart [chip-label] [line-offset]
//
// Needs access to /dev/gpiochip*; see the README for the udev rule.
import 'dart:io';

import 'package:gpio/gpio.dart';

Future<void> main(List<String> args) async {
  final label = args.isNotEmpty ? args[0] : 'pinctrl-rp1';
  final offset = args.length > 1 ? int.parse(args[1]) : 17;

  // By label, never by index: chip numbering follows probe order and moves
  // between kernels. On a Pi 5 the header is gpiochip0 or gpiochip4 depending
  // on how new the kernel is, but the label does not change.
  final chip = GpioChip.byLabel(label);
  print('Using ${chip.info.name} (${chip.info.label}), '
      '${chip.info.lineCount} lines');

  final request = chip.request(
    consumer: 'blink',
    lines: [LineConfig.output(offset)],
  );

  try {
    for (var i = 0; i < 10; i++) {
      request.setValue(offset, value: i.isEven);
      stdout.write(i.isEven ? '*' : '.');
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    stdout.writeln();
  } finally {
    request.setValue(offset, value: false);
    await request.close();
    chip.close();
  }
}
