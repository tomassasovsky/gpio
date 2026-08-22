import 'package:meta/meta.dart';

/// Which way a line is driven.
enum LineDirection {
  /// The line is read.
  input,

  /// The line is driven.
  output,
}

/// The edges that produce an event.
enum Edge {
  /// No edge detection; the line is read on demand only.
  none,

  /// Inactive to active.
  rising,

  /// Active to inactive.
  falling,

  /// Both transitions.
  both,
}

/// Internal pull resistor configuration.
enum Bias {
  /// Leave whatever the kernel or a previous consumer set.
  ///
  /// Not a synonym for [disabled]. On some SoCs — BCM2711 on a Raspberry Pi 4B
  /// among them — the pad's pull is programmed in the pin controller and
  /// survives the line being released, so a line can arrive already pulled by
  /// whoever held it last, and go on sourcing current into whatever is
  /// attached after `close()`. Ask for a bias explicitly when a defined state
  /// matters; do not read a released line as neutral.
  asIs,

  /// Disable both pulls.
  disabled,

  /// Pull up — the usual choice for a switch that shorts to ground.
  pullUp,

  /// Pull down.
  pullDown,
}

/// How an output line drives.
enum Drive {
  /// Drives both directions.
  pushPull,

  /// Drives low only; needs a pull-up. Safe to wire in parallel.
  openDrain,

  /// Drives high only; needs a pull-down.
  openSource,
}

/// Which clock stamps edge events.
enum EventClock {
  /// `CLOCK_MONOTONIC`. Immune to wall-clock adjustments, so it is the right
  /// choice for measuring intervals — and the default.
  monotonic,

  /// `CLOCK_REALTIME`. Comparable with wall-clock timestamps from elsewhere,
  /// at the cost of jumping when the clock is set.
  realtime,

  /// Hardware timestamping, where the controller supports it. Requests fail
  /// with `EINVAL` where it does not.
  hardware,
}

/// What a chip reports about itself.
@immutable
class GpioChipInfo {
  /// Creates chip information.
  const GpioChipInfo({
    required this.name,
    required this.label,
    required this.lineCount,
    required this.path,
  });

  /// Kernel device name, e.g. `gpiochip0`.
  ///
  /// Assigned by probe order, so it moves between kernels and boards. Prefer
  /// [label] to identify a controller.
  final String name;

  /// Driver-assigned label, e.g. `pinctrl-rp1` on a Raspberry Pi 5.
  ///
  /// Stable for a given controller, which is what makes it the right handle.
  final String label;

  /// How many lines this chip exposes.
  final int lineCount;

  /// The character device, e.g. `/dev/gpiochip0`.
  final String path;

  @override
  String toString() =>
      'GpioChipInfo($name, label: $label, lines: $lineCount, path: $path)';
}

/// What a chip reports about one line.
@immutable
class GpioLineInfo {
  /// Creates line information.
  const GpioLineInfo({
    required this.offset,
    required this.name,
    required this.consumer,
    required this.direction,
    required this.used,
    required this.activeLow,
    required this.bias,
    required this.drive,
    required this.edge,
    required this.debouncePeriod,
  });

  /// Index of the line on its chip.
  final int offset;

  /// Name the driver or device tree gives the line, or `''` if unnamed.
  final String name;

  /// Label of whoever currently holds the line, or `''` if free.
  final String consumer;

  /// Whether the line is currently an input or an output.
  final LineDirection direction;

  /// Whether some consumer — this process or another — holds the line.
  final bool used;

  /// Whether the line's logical state is inverted relative to its voltage.
  final bool activeLow;

  /// The line's configured bias.
  ///
  /// This is what the *request* asked for, not what the pad is doing.
  /// [Bias.asIs] means no bias was specified — it does not mean no pull is
  /// present, since a pull programmed by a previous consumer can outlive the
  /// request that set it. See [Bias.asIs].
  final Bias bias;

  /// The line's drive mode. Meaningless for inputs.
  final Drive drive;

  /// Which edges, if any, currently produce events.
  final Edge edge;

  /// Kernel-side debounce period, or [Duration.zero] when unset.
  final Duration debouncePeriod;

  @override
  String toString() => 'GpioLineInfo($offset'
      '${name.isEmpty ? '' : ' "$name"'}, '
      '${direction.name}'
      '${used ? ', used by "$consumer"' : ', free'})';
}
