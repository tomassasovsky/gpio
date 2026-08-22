// A bench harness for checking this package against real silicon.
//
// Everything in the test suite runs against either FakeKernel or gpio-sim.
// Both are real enough to catch a lot, and neither has a voltage in it. These
// modes are the ones that need a physical pin, a multimeter, and a person.
//
// Compiled by CI into a self-contained binary, because the boards this is
// aimed at (a Yocto image, say) have no Dart runtime to run a script with.
//
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:gpio/gpio.dart';

const _defaultChipLabel = 'pinctrl-bcm2711'; // Raspberry Pi 4B.
const _defaultOut = 17;
const _defaultIn = 27;

void _say(String line) {
  print(line);
  // Over ssh this is a pipe, not a tty, so Dart buffers it. Nobody can follow
  // a countdown that arrives all at once when the process exits.
  stdout.flush().ignore();
}

Future<void> main(List<String> argv) async {
  final args = _Args.parse(argv);
  if (args == null) {
    _usage();
    exit(64); // EX_USAGE
  }

  try {
    await _run(args);
  } on GpioException catch (e) {
    _say('');
    _say('FAILED: $e');
    exit(1);
    // _requireFree throws StateError to refuse a line the firmware holds.
    // That is a normal outcome on an appliance image, not a defect, so it
    // gets a readable message rather than a stack trace.
    // ignore: avoid_catching_errors
  } on StateError catch (e) {
    _say('');
    _say('FAILED: ${e.message}');
    exit(1);
  }
}

const _modes = {
  'info',
  'blink',
  'bias',
  'activelow',
  'drive',
  'switch',
  'loopback',
};

Future<void> _run(_Args args) async {
  // Validate before opening anything: `--help` and a typo must not fail with
  // "no GPIO chip labelled ..." from a chip lookup they never asked for.
  if (!_modes.contains(args.mode)) {
    _usage();
    exit(args.mode == '--help' || args.mode == '-h' ? 0 : 64);
  }

  _say('gpio hardware check');
  _say('chip label : ${args.chipLabel}');
  _say('mode       : ${args.mode}');
  _say('');

  final chip = args.chipPath != null
      ? GpioChip.byPath(args.chipPath!)
      : GpioChip.byLabel(args.chipLabel);
  try {
    switch (args.mode) {
      case 'info':
        _info(chip, args);
      case 'blink':
        await _blink(chip, args);
      case 'bias':
        await _bias(chip, args);
      case 'activelow':
        await _activeLow(chip, args);
      case 'drive':
        await _drive(chip, args);
      case 'switch':
        await _switchTest(chip, args);
      case 'loopback':
        await _loopback(chip, args);
    }
  } finally {
    await chip.close();
  }
}

// ---------------------------------------------------------------------------
// info
// ---------------------------------------------------------------------------

void _info(GpioChip chip, _Args args) {
  _say('chip   : ${chip.info.name}  (${chip.info.path})');
  _say('label  : ${chip.info.label}');
  _say('lines  : ${chip.info.lineCount}');
  _say('');

  // Whether device-tree line names resolve at all is a real open question on
  // a Pi 4B, and it decides whether findLine() is usable there or callers are
  // stuck with raw offsets.
  final named = <GpioLineInfo>[];
  for (var i = 0; i < chip.info.lineCount; i++) {
    final line = chip.lineInfo(i);
    if (line.name.isNotEmpty) named.add(line);
  }
  if (named.isEmpty) {
    _say('No line on this chip has a device-tree name.');
    _say('findLine() cannot work here; use offsets.');
  } else {
    _say('${named.length} of ${chip.info.lineCount} lines are named, e.g.:');
    for (final line in named.take(8)) {
      _say('  ${line.offset.toString().padLeft(3)}  ${line.name}');
    }
  }
  _say('');

  for (final offset in {args.out, args.inPin}) {
    _describe(chip, offset);
  }
}

void _describe(GpioChip chip, int offset) {
  final line = chip.lineInfo(offset);
  final held = line.used ? 'HELD by "${line.consumer}"' : 'free';
  _say('line $offset: $held');
  _say('  name      : ${line.name.isEmpty ? '(unnamed)' : line.name}');
  _say('  direction : ${line.direction.name}');
  _say('  bias      : ${line.bias.name}');
  _say('  drive     : ${line.drive.name}');
  _say('  activeLow : ${line.activeLow}');
  _say('  edge      : ${line.edge.name}');
  _say('  debounce  : ${line.debouncePeriod.inMicroseconds} us');
  _say('');
}

/// Refuses to touch a line another process is holding.
///
/// On a running appliance image this is the likely outcome, and `EBUSY` from
/// the kernel reads like a bug in the package rather than what it is.
void _requireFree(GpioChip chip, int offset) {
  final line = chip.lineInfo(offset);
  if (!line.used) return;
  throw StateError(
    'Line $offset is already held by "${line.consumer}". Stop that process, '
    'or pick a different pin with --out/--in. This is the firmware holding '
    'the line, not a failure of this package.',
  );
}

// ---------------------------------------------------------------------------
// blink — for a multimeter
// ---------------------------------------------------------------------------

Future<void> _blink(GpioChip chip, _Args args) async {
  _requireFree(chip, args.out);
  _say('Put the multimeter between GPIO${args.out} and any GND pin.');
  _say('Expect it to alternate 0 V and ~3.3 V every ${args.dwell}s.');
  _say('');

  final request = chip.request(
    consumer: 'gpio-hwcheck',
    lines: [LineConfig.output(args.out)],
  );
  try {
    var value = false;
    final deadline = DateTime.now().add(Duration(seconds: args.seconds));
    while (DateTime.now().isBefore(deadline)) {
      value = !value;
      request.setValue(args.out, value: value);
      final readBack = request.getValue(args.out);
      final label = value ? 'HIGH  (expect ~3.3 V)' : 'LOW   (expect 0 V)';
      _say('${_clock()}  drive $label   readback=${readBack ? 1 : 0}');
      if (readBack != value) {
        _say('  !! read-back disagrees with what was written');
      }
      await Future<void>.delayed(Duration(seconds: args.dwell));
    }
    request.setValue(args.out, value: false);
    _say('');
    _say('Done. Line left LOW.');
  } finally {
    await request.close();
  }
}

// ---------------------------------------------------------------------------
// bias — the thing gpio-sim structurally cannot check
// ---------------------------------------------------------------------------

Future<void> _bias(GpioChip chip, _Args args) async {
  _requireFree(chip, args.inPin);
  _say('Leave GPIO${args.inPin} FLOATING — nothing connected to it.');
  _say('Measure between GPIO${args.inPin} and GND.');
  _say('');
  _say('There is no voltage in a simulated chip, so this is the one');
  _say('property no amount of gpio-sim testing can establish.');
  _say('');

  const cases = [
    (Bias.pullUp, '~3.3 V   (internal pull-up, ~50k to 3V3)'),
    (Bias.pullDown, '~0 V     (internal pull-down)'),
    (
      Bias.disabled,
      'floating (a meter reading here is meaningless — that is the point)',
    ),
  ];

  for (final (bias, expectation) in cases) {
    final request = chip.request(
      consumer: 'gpio-hwcheck',
      lines: [LineConfig.input(args.inPin, bias: bias)],
    );
    try {
      final readBack = chip.lineInfo(args.inPin);
      _say('${_clock()}  bias=${bias.name}  expect $expectation');
      _say('           kernel reports bias=${readBack.bias.name}, '
          'value reads ${request.getValue(args.inPin) ? 1 : 0}');
      if (readBack.bias != bias) {
        _say('  !! kernel did not report back the bias that was requested');
      }
      _say('           holding ${args.dwell}s...');
      await Future<void>.delayed(Duration(seconds: args.dwell));
      _say('');
    } finally {
      await request.close();
    }
  }
  _say('Done.');
}

// ---------------------------------------------------------------------------
// activelow — inversion at the pin, not in our bookkeeping
// ---------------------------------------------------------------------------

/// How long a pad needs to settle through a series resistor. Short enough
/// that nobody waiting at the bench notices it.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

/// Probes for a wire between [out] and [inPin].
///
/// Both lines are claimed in one request with no inversion anywhere, the
/// output is driven each way, and the input is read back. A wire counts as
/// present only if the input followed the output in *both* directions.
///
/// The input is pulled down for the probe rather than left floating. An
/// unconnected neighbour of a switching output will follow it through stray
/// capacitance and look exactly like a jumper; a push-pull driver beats a
/// ~50k pull-down, but coupling does not. Without this the probe reports a
/// witness that is not there, and the activeLow check then "confirms"
/// itself against noise.
Future<bool> _hasLoopback(GpioChip chip, int out, int inPin) async {
  if (out == inPin) return false;
  if (chip.lineInfo(inPin).used) return false;

  final request = chip.request(
    consumer: 'gpio-hwcheck',
    lines: [
      LineConfig.output(out),
      LineConfig.input(inPin, bias: Bias.pullDown),
    ],
  );
  try {
    request.setValue(out, value: true);
    await _settle();
    final followedHigh = request.getValue(inPin);
    request.setValue(out, value: false);
    await _settle();
    final followedLow = request.getValue(inPin);
    return followedHigh && !followedLow;
  } finally {
    await request.close();
  }
}

Future<void> _activeLow(GpioChip chip, _Args args) async {
  _requireFree(chip, args.out);

  // getValue() applies exactly the inversion setValue() does, so reading a
  // line back through its own request cannot distinguish an inversion that
  // reached the pad from one that never left our bookkeeping: both produce
  // byte-identical output. Confirming it needs a witness from outside the
  // inverting layer — either a person with a meter, or a second line on the
  // far end of a wire, read with no inversion of its own.
  final witnessed = await _hasLoopback(chip, args.out, args.inPin);

  if (witnessed) {
    _say('Jumper detected: GPIO${args.out} -> GPIO${args.inPin}.');
    _say('Reading the pad back through GPIO${args.inPin}, which carries no');
    _say('inversion of its own and so reports voltage rather than our logic.');
    _say('This run is self-verifying — no meter needed.');
  } else {
    _say('Measure between GPIO${args.out} and GND.');
    _say('');
    _say('!! No jumper between GPIO${args.out} and GPIO${args.inPin}, so this');
    _say('!! run CANNOT confirm the inversion on its own. getValue() inverts');
    _say('!! exactly as setValue() does, so the readback column below reads');
    _say('!! the same whether the inversion reaches the pin or stops at our');
    _say('!! bookkeeping. The meter is the only witness in this mode.');
    _say('!!');
    _say('!! For a conclusive run, jumper the two pins together through');
    _say('!! ~330 ohms and run again — it detects the wire by itself.');
  }
  _say('');

  var checked = 0;
  var mismatched = 0;

  for (final activeLow in [false, true]) {
    for (final value in [true, false]) {
      final request = chip.request(
        consumer: 'gpio-hwcheck',
        lines: [
          LineConfig.output(args.out, activeLow: activeLow),
          if (witnessed) LineConfig.input(args.inPin, bias: Bias.pullDown),
        ],
      );
      try {
        request.setValue(args.out, value: value);
        // activeLow inverts, so the pad is the logical value XOR the flag.
        final expectedHigh = value != activeLow;
        final volts = expectedHigh ? '~3.3 V' : '0 V';
        _say(
          '${_clock()}  activeLow=$activeLow  setValue($value)  '
          'expect $volts   readback=${request.getValue(args.out) ? 1 : 0}',
        );
        if (witnessed) {
          await _settle();
          final pad = request.getValue(args.inPin);
          checked++;
          if (pad == expectedHigh) {
            _say('           pad via GPIO${args.inPin} reads '
                '${pad ? 1 : 0}   OK');
          } else {
            mismatched++;
            _say('           pad via GPIO${args.inPin} reads '
                '${pad ? 1 : 0}   !! expected ${expectedHigh ? 1 : 0}');
            _say('  !! the inversion did not reach the pin');
          }
        }
        _say('           holding ${args.dwell}s...');
        await Future<void>.delayed(Duration(seconds: args.dwell));
      } finally {
        await request.close();
      }
    }
  }

  _say('');
  if (witnessed) {
    _say('pad checks   : $checked');
    _say('mismatches   : $mismatched');
    if (mismatched == 0) {
      _say('activeLow inverts at the pin, confirmed against a second line.');
    } else {
      // The wire was good when the run started, but saying "this is a real
      // defect" is only honest if it is still good now.
      final stillWired = await _hasLoopback(chip, args.out, args.inPin);
      if (stillWired) {
        _say('activeLow did NOT invert at the pin, and the jumper is still');
        _say('good — it was re-probed after the run. This is a real defect.');
      } else {
        _say('Mismatches were seen, but the jumper is no longer detected.');
        _say('The wire most likely came off mid-run. Re-seat it and repeat');
        _say('before reading anything into this.');
      }
    }
  } else {
    _say('Nothing above was confirmed by this process. See the warning.');
  }
  _say('Done.');
}

// ---------------------------------------------------------------------------
// drive — push-pull vs open-drain
// ---------------------------------------------------------------------------

Future<void> _drive(GpioChip chip, _Args args) async {
  _requireFree(chip, args.out);
  _say('Measure between GPIO${args.out} and GND.');
  _say('');
  _say('Open-drain can pull LOW but not drive HIGH — driving high just');
  _say('releases the pin. With the internal pull-up enabled the meter');
  _say('should still read ~3.3 V, but it is the resistor doing it, so it');
  _say('will sag under any load a push-pull output would hold up.');
  _say('');

  for (final drive in [Drive.pushPull, Drive.openDrain]) {
    for (final value in [true, false]) {
      final request = chip.request(
        consumer: 'gpio-hwcheck',
        lines: [
          LineConfig.output(args.out, drive: drive, bias: Bias.pullUp),
        ],
      );
      try {
        request.setValue(args.out, value: value);
        final reported = chip.lineInfo(args.out);
        _say(
          '${_clock()}  drive=${drive.name}  setValue($value)  '
          'expect ${value ? '~3.3 V' : '0 V'}',
        );
        _say('           kernel reports drive=${reported.drive.name}');
        if (reported.drive != drive) {
          _say('  !! kernel did not report back the drive mode requested');
        }
        _say('           holding ${args.dwell}s...');
        await Future<void>.delayed(Duration(seconds: args.dwell));
      } finally {
        await request.close();
      }
    }
  }
  _say('');
  _say('Done.');
}

// ---------------------------------------------------------------------------
// switch — a real contact, with real bounce
// ---------------------------------------------------------------------------

Future<void> _switchTest(GpioChip chip, _Args args) async {
  _requireFree(chip, args.inPin);
  final debounce = args.debounce;
  _say('Wire a switch (or just a jumper wire) between GPIO${args.inPin} '
      'and GND.');
  _say('The internal pull-up holds it HIGH; closing it pulls LOW.');
  _say('');
  if (debounce > Duration.zero) {
    _say('Kernel debounce: ${debounce.inMilliseconds} ms');
    _say('Run once WITHOUT --debounce and once with, and compare the edge');
    _say('counts. That difference is the debouncer doing its job.');
  } else {
    _say('No debounce. A hand-held wire scraping a header pin is a filthy');
    _say('contact, so expect bursts of edges per touch.');
  }
  _say('');
  _say('Listening for ${args.seconds}s. Press/tap now.');
  _say('');

  final request = chip.request(
    consumer: 'gpio-hwcheck',
    lines: [
      LineConfig.input(
        args.inPin,
        bias: Bias.pullUp,
        edge: Edge.both,
        debounce: debounce,
      ),
    ],
  );

  // What the kernel actually accepted, read back while the request is still
  // held. A released line always reports zero here, which is exactly why this
  // had never been checked: `info` only ever inspects free lines.
  final held = chip.lineInfo(args.inPin);
  _say('kernel reports: debounce=${held.debouncePeriod.inMicroseconds} us  '
      'edge=${held.edge.name}  bias=${held.bias.name}');
  if (held.debouncePeriod != debounce) {
    _say('  !! kernel did not report back the debounce that was requested '
        '(asked ${debounce.inMicroseconds} us)');
  }
  if (held.edge != Edge.both) {
    _say('  !! kernel did not report back the edge mode requested');
  }
  _say('');

  var edges = 0;
  var dropped = 0;
  int? lastNs;
  final gaps = <int>[];

  final sub = request.events.listen((event) {
    switch (event) {
      case LineEdgeEvent(:final edge, :final timestampNs, :final seqno):
        edges++;
        final gap = lastNs == null ? null : timestampNs - lastNs!;
        lastNs = timestampNs;
        if (gap != null) gaps.add(gap);
        _say(
          '${_clock()}  ${edge.name.padRight(7)} seq=$seqno  '
          '${gap == null ? '' : '+${_us(gap)} since previous'}',
        );
      case LineEventsDropped(:final count):
        dropped += count;
        _say('${_clock()}  !! kernel dropped $count events (FIFO overflow)');
    }
  });

  await Future<void>.delayed(Duration(seconds: args.seconds));
  await sub.cancel();
  await request.close();

  _say('');
  _say('edges seen   : $edges');
  _say('events lost  : $dropped');
  if (gaps.isNotEmpty) {
    gaps.sort();
    _say('shortest gap : ${_us(gaps.first)}');
    _say('median gap   : ${_us(gaps[gaps.length ~/ 2])}');
    _say('longest gap  : ${_us(gaps.last)}');
    if (debounce == Duration.zero && gaps.first < 1000000) {
      _say('');
      _say('A sub-millisecond gap is contact bounce. Re-run with');
      _say('--debounce 5 and it should disappear.');
    }
  }
  if (edges == 0) {
    _say('');
    _say('No edges at all. Check the wiring, and that GPIO${args.inPin} is');
    _say('the pin you actually touched — header pin numbers are not GPIO');
    _say('numbers.');
  }
}

// ---------------------------------------------------------------------------
// loopback — the latency number
// ---------------------------------------------------------------------------

Future<void> _loopback(GpioChip chip, _Args args) async {
  _requireFree(chip, args.out);
  _requireFree(chip, args.inPin);
  _say('Jumper GPIO${args.out} to GPIO${args.inPin}, ideally through a');
  _say('~330 ohm resistor so a misconfiguration cannot short two outputs.');
  _say('');
  _say('This measures drive-to-event latency end to end: the setValue call,');
  _say('the kernel interrupt, the poll wakeup, the isolate hop, and the');
  _say('delivery to a Dart listener. It is the number the package is');
  _say('ultimately judged on, and it has never been measured.');
  _say('');

  final request = chip.request(
    consumer: 'gpio-hwcheck',
    lines: [
      LineConfig.output(args.out),
      LineConfig.input(args.inPin, edge: Edge.both),
    ],
  );

  final latencies = <int>[];
  Completer<void>? pending;
  var mismatches = 0;
  var expected = false;

  final sw = Stopwatch();
  final sub = request.events.listen((event) {
    if (event is! LineEdgeEvent) {
      _say('${_clock()}  !! ${event.runtimeType} during loopback');
      return;
    }
    latencies.add(sw.elapsedMicroseconds);
    final sawRising = event.edge == Edge.rising;
    if (sawRising != expected) {
      mismatches++;
      final drove = expected ? 'HIGH' : 'LOW';
      _say('  !! drove $drove but saw ${event.edge.name}');
    }
    pending?.complete();
  });

  const rounds = 20;
  for (var i = 0; i < rounds; i++) {
    expected = i.isEven;
    pending = Completer<void>();
    sw
      ..reset()
      ..start();
    request.setValue(args.out, value: expected);
    await pending.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _say('  !! no event within 2s for round $i — is the jumper on?');
      },
    );
    sw.stop();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  await sub.cancel();
  await request.close();

  _say('');
  if (latencies.isEmpty) {
    _say('No events at all. The jumper is not connecting '
        'GPIO${args.out} to GPIO${args.inPin}.');
    return;
  }
  latencies.sort();
  _say('round trips  : ${latencies.length} of $rounds');
  _say('edge mismatch: $mismatches');
  _say('min          : ${_us(latencies.first * 1000)}');
  _say('median       : ${_us(latencies[latencies.length ~/ 2] * 1000)}');
  _say('p90          : ${_us(latencies[(latencies.length * 9) ~/ 10] * 1000)}');
  _say('max          : ${_us(latencies.last * 1000)}');
  _say('');
  _say('These are userspace-to-userspace, so they include the isolate hop.');
  _say('The kernel timestamp on each event is stamped in the interrupt');
  _say('handler and is unaffected by any of that delay.');
}

// ---------------------------------------------------------------------------

String _clock() {
  final now = DateTime.now();
  final h = now.hour.toString().padLeft(2, '0');
  final m = now.minute.toString().padLeft(2, '0');
  final s = now.second.toString().padLeft(2, '0');
  final ms = now.millisecond.toString().padLeft(3, '0');
  return '$h:$m:$s.$ms';
}

/// Nanoseconds, printed in whatever unit keeps it readable.
String _us(int ns) {
  if (ns < 1000) return '${ns}ns';
  if (ns < 1000000) return '${(ns / 1000).toStringAsFixed(1)}us';
  if (ns < 1000000000) return '${(ns / 1000000).toStringAsFixed(2)}ms';
  return '${(ns / 1000000000).toStringAsFixed(2)}s';
}

class _Args {
  _Args({
    required this.mode,
    required this.chipLabel,
    required this.chipPath,
    required this.out,
    required this.inPin,
    required this.seconds,
    required this.dwell,
    required this.debounce,
  });

  static _Args? parse(List<String> argv) {
    if (argv.isEmpty) return null;
    final mode = argv.first;
    var chipLabel = _defaultChipLabel;
    String? chipPath;
    var out = _defaultOut;
    var inPin = _defaultIn;
    var seconds = 60;
    var dwell = 5;
    var debounceMs = 0;

    for (var i = 1; i < argv.length - 1; i += 2) {
      final value = argv[i + 1];
      switch (argv[i]) {
        case '--chip':
          chipLabel = value;
        case '--path':
          chipPath = value;
        case '--out':
          out = int.tryParse(value) ?? out;
        case '--in':
          inPin = int.tryParse(value) ?? inPin;
        case '--seconds':
          seconds = int.tryParse(value) ?? seconds;
        case '--dwell':
          dwell = int.tryParse(value) ?? dwell;
        case '--debounce':
          debounceMs = int.tryParse(value) ?? debounceMs;
        default:
          return null;
      }
    }
    return _Args(
      mode: mode,
      chipLabel: chipLabel,
      chipPath: chipPath,
      out: out,
      inPin: inPin,
      seconds: seconds,
      dwell: dwell,
      debounce: Duration(milliseconds: debounceMs),
    );
  }

  final String mode;
  final String chipLabel;
  final String? chipPath;
  final int out;
  final int inPin;
  final int seconds;
  final int dwell;
  final Duration debounce;
}

void _usage() {
  _say('''
gpio hardware check — bench verification against real silicon

  gpio-hwcheck <mode> [options]

Modes
  info        enumerate chips and dump line info for the pins under test
  blink       toggle an output slowly, for a multimeter
  bias        cycle pull-up / pull-down / disabled on a floating input
  activelow   drive with and without activeLow; conclusive when out is
              jumpered to in, meter-only otherwise (it tells you which)
  drive       push-pull vs open-drain
  switch      watch edges from a switch or a jumper to GND
  loopback    jumper out->in; measure drive-to-event latency

Options
  --chip LABEL     chip label            (default $_defaultChipLabel)
  --path /dev/...  chip by path instead of label
  --out N          output GPIO offset    (default $_defaultOut)
  --in N           input GPIO offset     (default $_defaultIn)
  --seconds N      total run time        (default 60)
  --dwell N        seconds per step      (default 5)
  --debounce MS    kernel debounce, switch mode only (default 0)

Offsets are GPIO numbers, not header pin numbers. Needs root, or membership
of the gpio group.

Examples
  sudo ./gpio-hwcheck info
  sudo ./gpio-hwcheck blink --out 17 --dwell 5 --seconds 60
  sudo ./gpio-hwcheck bias --in 27
  sudo ./gpio-hwcheck switch --in 27 --seconds 30
  sudo ./gpio-hwcheck switch --in 27 --seconds 30 --debounce 5
  sudo ./gpio-hwcheck activelow --out 17 --in 27   # self-verifying
  sudo ./gpio-hwcheck loopback --out 17 --in 27
''');
}
