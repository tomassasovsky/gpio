import 'package:gpio/src/models.dart';
import 'package:meta/meta.dart';

/// `enum gpio_v2_line_flag` — the kernel's per-line bitfield.
///
/// Named here rather than taken from the generated enum because the generated
/// form is a Dart `enum` of named constants, and these need to be OR-ed
/// together as a bitmask.
class LineFlag {
  const LineFlag._();

  /// The line is already requested by someone.
  static const int used = 1 << 0;

  /// Logical state is inverted relative to voltage.
  static const int activeLow = 1 << 1;

  /// The line is an input.
  static const int input = 1 << 2;

  /// The line is an output.
  static const int output = 1 << 3;

  /// Detect inactive-to-active transitions.
  static const int edgeRising = 1 << 4;

  /// Detect active-to-inactive transitions.
  static const int edgeFalling = 1 << 5;

  /// Output drives low only.
  static const int openDrain = 1 << 6;

  /// Output drives high only.
  static const int openSource = 1 << 7;

  /// Enable the internal pull-up.
  static const int biasPullUp = 1 << 8;

  /// Enable the internal pull-down.
  static const int biasPullDown = 1 << 9;

  /// Disable internal bias.
  static const int biasDisabled = 1 << 10;

  /// Stamp events with `CLOCK_REALTIME`.
  static const int eventClockRealtime = 1 << 11;

  /// Stamp events with a hardware timestamp engine.
  static const int eventClockHardware = 1 << 12;
}

/// How one line should be configured within a request.
@immutable
class LineConfig {
  const LineConfig._({
    required this.offset,
    required this.direction,
    this.activeLow = false,
    this.bias = Bias.asIs,
    this.drive = Drive.pushPull,
    this.edge = Edge.none,
    this.debounce = Duration.zero,
    this.initialValue = false,
  });

  /// Configures [offset] as an input.
  ///
  /// [debounce] asks the *kernel* to suppress transitions shorter than the
  /// given period — contact bounce is filtered below userspace, so no timer of
  /// yours is involved and the timestamps you receive are already clean. It is
  /// only meaningful alongside an [edge] other than [Edge.none].
  const LineConfig.input(
    int offset, {
    Bias bias = Bias.asIs,
    Edge edge = Edge.none,
    Duration debounce = Duration.zero,
    bool activeLow = false,
  }) : this._(
          offset: offset,
          direction: LineDirection.input,
          bias: bias,
          edge: edge,
          debounce: debounce,
          activeLow: activeLow,
        );

  /// Configures [offset] as an output, driven to [initialValue] at request
  /// time.
  ///
  /// The initial value is applied by the same ioctl that claims the line, so
  /// the line never passes through an undefined state on the way to the value
  /// you asked for.
  const LineConfig.output(
    int offset, {
    bool initialValue = false,
    Drive drive = Drive.pushPull,
    Bias bias = Bias.asIs,
    bool activeLow = false,
  }) : this._(
          offset: offset,
          direction: LineDirection.output,
          initialValue: initialValue,
          drive: drive,
          bias: bias,
          activeLow: activeLow,
        );

  /// The line's index on its chip.
  final int offset;

  /// Whether the line is read or driven.
  final LineDirection direction;

  /// Whether to invert the logical sense of the line.
  final bool activeLow;

  /// Internal pull configuration.
  final Bias bias;

  /// Drive mode. Ignored for inputs.
  final Drive drive;

  /// Which edges produce events. Ignored for outputs.
  final Edge edge;

  /// Kernel-side debounce period. Ignored for outputs.
  final Duration debounce;

  /// Value an output is driven to when the request is made.
  final bool initialValue;

  /// This line's contribution to `gpio_v2_line_config.flags`.
  int get flags {
    var f = direction == LineDirection.input ? LineFlag.input : LineFlag.output;
    if (activeLow) f |= LineFlag.activeLow;

    f |= switch (bias) {
      Bias.asIs => 0,
      Bias.disabled => LineFlag.biasDisabled,
      Bias.pullUp => LineFlag.biasPullUp,
      Bias.pullDown => LineFlag.biasPullDown,
    };

    if (direction == LineDirection.output) {
      f |= switch (drive) {
        Drive.pushPull => 0,
        Drive.openDrain => LineFlag.openDrain,
        Drive.openSource => LineFlag.openSource,
      };
    } else {
      f |= switch (edge) {
        Edge.none => 0,
        Edge.rising => LineFlag.edgeRising,
        Edge.falling => LineFlag.edgeFalling,
        Edge.both => LineFlag.edgeRising | LineFlag.edgeFalling,
      };
    }
    return f;
  }

  /// Whether this line asks for edge events.
  bool get wantsEvents => direction == LineDirection.input && edge != Edge.none;

  /// Debounce period in microseconds, as the kernel attribute wants it.
  int get debounceMicros => debounce.inMicroseconds;

  @override
  String toString() => 'LineConfig($offset, ${direction.name}'
      '${edge == Edge.none ? '' : ', ${edge.name}'}'
      '${debounce == Duration.zero ? '' : ', debounce: '
          '${debounce.inMicroseconds}us'})';
}

/// Flags contributed by request-wide settings rather than by one line.
int eventClockFlag(EventClock clock) => switch (clock) {
      EventClock.monotonic => 0,
      EventClock.realtime => LineFlag.eventClockRealtime,
      EventClock.hardware => LineFlag.eventClockHardware,
    };
