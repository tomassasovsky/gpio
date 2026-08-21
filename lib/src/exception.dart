import 'package:gpio/src/ffi/libc.dart';
import 'package:meta/meta.dart';

/// A failure from the GPIO character device.
///
/// Carries the raw [errno] so callers can branch on it, and a message that
/// tries to say what to actually do about it. A GPIO library that reports
/// "ioctl failed: 13" has wasted the one chance it had to be useful.
@immutable
class GpioException implements Exception {
  /// Creates an exception for [operation] failing with [errno].
  GpioException(this.operation, this.errno, {this.path, this.consumer})
      : message = _explain(errno, operation, path, consumer);

  /// The call that failed, e.g. `GPIO_V2_GET_LINE`.
  final String operation;

  /// The C `errno` value.
  final int errno;

  /// The device involved, when there was one.
  final String? path;

  /// For [Errno.ebusy], the consumer already holding the line, when known.
  final String? consumer;

  /// A human-readable explanation, with a remedy where one exists.
  final String message;

  /// Whether the line is held by another consumer.
  bool get isBusy => errno == Errno.ebusy;

  /// Whether this is a permissions problem.
  bool get isPermissionDenied => errno == Errno.eacces || errno == Errno.eperm;

  static String _explain(
    int errno,
    String operation,
    String? path,
    String? consumer,
  ) {
    final where = path == null ? '' : ' on $path';
    return switch (errno) {
      Errno.eacces || Errno.eperm => '$operation$where: permission denied. '
          'GPIO character devices are root-only by default. Add a udev rule '
          '(SUBSYSTEM=="gpio", KERNEL=="gpiochip*", GROUP="gpio", '
          'MODE="0660") and put this user in the gpio group, or run as root.',
      Errno.ebusy => '$operation$where: the line is already requested'
          '${consumer == null || consumer.isEmpty ? '' : ' by "$consumer"'}. '
          'A line can have only one consumer. If that name is this program, '
          'a previous request is still open — on Flutter, a hot restart '
          'leaves the descriptor alive; a full restart releases it.',
      Errno.enoent => '$operation$where: no such device. Chip numbering '
          'follows probe order and moves between kernels — look the chip up '
          'by label rather than by index.',
      Errno.enotty => '$operation$where: not a GPIO character device, or this '
          'kernel does not know the v2 GPIO interface. That interface needs '
          'Linux 5.10 or newer; this package does not implement the '
          'deprecated v1 fallback.',
      Errno.einval => '$operation$where: the kernel rejected the request as '
          'invalid. Common causes: a line offset beyond the chip, more than '
          '64 lines in one request, edge detection asked for on an output, '
          'or an event clock the controller does not support.',
      Errno.enodev => '$operation$where: the device has gone away.',
      Errno.ebadf => '$operation$where: the descriptor is closed.',
      _ => '$operation$where failed with errno $errno.',
    };
  }

  @override
  String toString() => 'GpioException: $message';
}
