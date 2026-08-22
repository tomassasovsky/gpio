/// Linux GPIO from pure Dart, over the `/dev/gpiochip*` character device using
/// the v2 userspace ABI.
///
/// No native library, no bundled binaries — `dart:ffi` and the libc already in
/// the process.
///
/// ```dart
/// final chip = GpioChip.byLabel('pinctrl-rp1');
/// final request = chip.request(
///   consumer: 'my-app',
///   lines: [
///     LineConfig.input(17, bias: Bias.pullUp, edge: Edge.both,
///                      debounce: Duration(milliseconds: 5)),
///     LineConfig.output(27, initialValue: false),
///   ],
/// );
/// print(request.getValue(17));
/// request.setValue(27, value: true);
/// await request.close();
/// await chip.close();
/// ```
///
/// Look chips up by **label**, never by index: numbering follows probe order
/// and moves between kernels and boards.
library;

export 'src/chip.dart' show GpioChip;
export 'src/events.dart'
    show
        LineChangeKind,
        LineEdgeEvent,
        LineEvent,
        LineEventsDropped,
        LineInfoChanged;
export 'src/exception.dart';
export 'src/line_config.dart' show LineConfig;
export 'src/line_request.dart';
export 'src/models.dart';
export 'src/syscalls.dart' show Syscalls;
