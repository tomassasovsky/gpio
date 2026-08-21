import 'dart:io';

/// Drives the kernel's own `gpio-sim` module through configfs.
///
/// This is what libgpiod's test suite uses, and it is the only way to exercise
/// the real ioctl path without physical hardware: the chips it creates are
/// genuine `/dev/gpiochipN` devices served by the same gpiolib code as a real
/// controller.
///
/// Needs root and `CONFIG_GPIO_SIM`. [isAvailable] reports whether both hold,
/// so the suite can skip rather than fail where they do not.
class GpioSim {
  GpioSim._(this._deviceDir, this.chipPath, this._bankDir);

  /// Creates a simulated chip with [lineCount] lines.
  factory GpioSim.create({
    required String name,
    required String label,
    int lineCount = 8,
  }) {
    final deviceDir = '$_configfs/$name';
    final bankDir = '$deviceDir/bank0';
    Directory(bankDir).createSync(recursive: true);

    File('$bankDir/num_lines').writeAsStringSync('$lineCount');
    File('$bankDir/label').writeAsStringSync(label);
    File('$deviceDir/live').writeAsStringSync('1');

    // The kernel reports which /dev node it allocated.
    final chipName = File('$bankDir/chip_name').readAsStringSync().trim();
    return GpioSim._(deviceDir, '/dev/$chipName', bankDir);
  }

  static const _configfs = '/sys/kernel/config/gpio-sim';

  /// Whether a simulated chip can be created here.
  static bool get isAvailable {
    if (!Platform.isLinux) return false;
    if (Directory(_configfs).existsSync()) return true;
    // The module may simply not be loaded yet.
    Process.runSync('modprobe', ['gpio-sim']);
    return Directory(_configfs).existsSync();
  }

  /// Why [isAvailable] is false, for a useful skip message.
  static String get unavailableReason {
    if (!Platform.isLinux) return 'not Linux';
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    if (uid != '0') return 'needs root (configfs is root-only)';
    return 'gpio-sim not available (CONFIG_GPIO_SIM missing?)';
  }

  final String _deviceDir;
  final String _bankDir;

  /// The `/dev/gpiochipN` this simulated chip appears as.
  final String chipPath;

  /// Drives a line from the simulated "outside world".
  void setPull(int offset, {required bool high}) {
    File('$_bankDir/sim_gpio$offset/pull')
        .writeAsStringSync(high ? 'pull-up' : 'pull-down');
  }

  /// Reads what the chip currently presents on [offset].
  bool value(int offset) =>
      File('$_bankDir/sim_gpio$offset/value').readAsStringSync().trim() == '1';

  /// Tears the simulated chip down.
  void destroy() {
    try {
      File('$_deviceDir/live').writeAsStringSync('0');
      Directory(_bankDir).deleteSync();
      Directory(_deviceDir).deleteSync();
    } on FileSystemException {
      // Best effort: a failed teardown must not mask a test failure.
    }
  }
}
