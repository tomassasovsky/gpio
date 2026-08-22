// Watches a button and reports every edge the kernel sees.
//
//   dart run example/button.dart [chip-label] [line-offset]
//
// Wire a momentary switch between the pin and ground: the internal pull-up
// holds it high, and `activeLow` then makes a press read as `true`.
import 'dart:async';
import 'dart:io';

import 'package:gpio/gpio.dart';

Future<void> main(List<String> args) async {
  final label = args.isNotEmpty ? args[0] : 'pinctrl-rp1';
  final offset = args.length > 1 ? int.parse(args[1]) : 17;

  final chip = GpioChip.byLabel(label);
  final request = chip.request(
    consumer: 'button',
    lines: [
      LineConfig.input(
        offset,
        bias: Bias.pullUp,
        activeLow: true,
        edge: Edge.both,
        // Filtered by the KERNEL, below userspace -- no timer of ours is
        // involved and the timestamps arrive already clean.
        debounce: const Duration(milliseconds: 5),
      ),
    ],
  );

  print('Watching line $offset. Ctrl-C to stop.');
  print('Currently: ${request.getValue(offset) ? "pressed" : "released"}');

  final subscription = request.events.listen((event) {
    switch (event) {
      case LineEdgeEvent(:final edge, :final timestampNs):
        final what = edge == Edge.rising ? 'pressed ' : 'released';
        // Nanoseconds, straight from the kernel's interrupt handler.
        print('$what at ${timestampNs / 1e6} ms (seq ${event.seqno})');
      case LineEventsDropped(:final count):
        // Worth acting on: a real press was missed. Raise eventBufferSize, or
        // lengthen the debounce so the chatter never reaches the FIFO.
        print('!! kernel dropped $count edges');
    }
  });

  await ProcessSignal.sigint.watch().first;
  await subscription.cancel();
  await request.close();
  await chip.close();
}
