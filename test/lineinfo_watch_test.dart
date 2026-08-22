import 'package:gpio/gpio.dart';
import 'package:gpio/gpio_testing.dart';
import 'package:gpio/src/ffi/ioctl.dart';
import 'package:test/test.dart';

void main() {
  late FakeKernel kernel;
  late GpioChip chip;

  setUp(() {
    kernel = FakeKernel.single();
    chip = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
  });

  group('watchLineInfo', () {
    test('issues the v2 watch ioctl, never a v1 one', () {
      chip.watchLineInfo([3]);
      expect(kernel.ioctlLog, contains(GpioIoctl.v2WatchLineInfo));
      // 0x0B is GPIO_GET_LINEINFO_WATCH_IOCTL, the v1 spelling.
      expect(kernel.ioctlLog.map((r) => r & 0xFF), isNot(contains(0x0B)));
    });

    test('reports another consumer claiming the line', () async {
      final changes = chip.watchLineInfo([3]);
      final seen = <LineInfoChanged>[];
      final sub = changes.listen(seen.add);

      // A second chip handle stands in for a different process entirely.
      final other = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
      final request = other.request(
        consumer: 'someone-else',
        lines: [const LineConfig.output(3)],
      );
      await pumpEventQueue();

      expect(seen, hasLength(1));
      expect(seen.single.kind, LineChangeKind.requested);
      expect(seen.single.offset, 3);
      expect(seen.single.info.consumer, 'someone-else');
      expect(seen.single.info.used, isTrue);

      await request.close();
      await sub.cancel();
      await other.close();
    });

    test('reports the release, with the consumer gone', () async {
      final seen = <LineInfoChanged>[];
      final sub = chip.watchLineInfo([3]).listen(seen.add);

      final other = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
      final request = other.request(
        consumer: 'someone-else',
        lines: [const LineConfig.output(3)],
      );
      await pumpEventQueue();
      await request.close();
      await pumpEventQueue();

      expect(seen.map((c) => c.kind), [
        LineChangeKind.requested,
        LineChangeKind.released,
      ]);
      expect(seen.last.info.consumer, isEmpty);
      expect(seen.last.info.used, isFalse);

      await sub.cancel();
      await other.close();
    });

    test('reports a reconfiguration of a line still held', () async {
      final seen = <LineInfoChanged>[];
      final sub = chip.watchLineInfo([3]).listen(seen.add);

      final other = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
      final request = other.request(
        consumer: 'someone-else',
        lines: [const LineConfig.output(3)],
      );
      await pumpEventQueue();
      request.reconfigure([
        const LineConfig.input(3, bias: Bias.pullUp, edge: Edge.both),
      ]);
      await pumpEventQueue();

      expect(seen.map((c) => c.kind), [
        LineChangeKind.requested,
        LineChangeKind.reconfigured,
      ]);
      expect(seen.last.info.direction, LineDirection.input);
      expect(seen.last.info.bias, Bias.pullUp);

      await request.close();
      await sub.cancel();
      await other.close();
    });

    test('says nothing about lines that are not watched', () async {
      final seen = <LineInfoChanged>[];
      final sub = chip.watchLineInfo([3]).listen(seen.add);

      final other = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
      final request = other.request(lines: [const LineConfig.output(5)]);
      await pumpEventQueue();

      expect(seen, isEmpty);

      await request.close();
      await sub.cancel();
      await other.close();
    });

    test('unwatch stops the reports', () async {
      final seen = <LineInfoChanged>[];
      final sub = chip.watchLineInfo([3]).listen(seen.add);
      chip.unwatchLineInfo(3);
      expect(chip.watchedLines, isEmpty);

      final other = GpioChip.byLabel('fake-pinctrl', syscalls: kernel);
      final request = other.request(lines: [const LineConfig.output(3)]);
      await pumpEventQueue();

      expect(seen, isEmpty);

      await request.close();
      await sub.cancel();
      await other.close();
    });

    test('unwatching a line that was never watched is not an error', () {
      expect(() => chip.unwatchLineInfo(4), returnsNormally);
    });

    test('watching the same line twice does not fail', () {
      // The kernel answers EBUSY for a duplicate watch on one descriptor;
      // asking twice for the same thing is not the caller's mistake, so the
      // second is skipped rather than surfaced.
      chip.watchLineInfo([3]);
      expect(() => chip.watchLineInfo([3, 4]), returnsNormally);
      expect(chip.watchedLines, [3, 4]);
    });

    test('rejects an empty offset list', () {
      expect(() => chip.watchLineInfo([]), throwsArgumentError);
    });

    test('rejects an offset the chip does not have', () {
      expect(() => chip.watchLineInfo([99]), throwsRangeError);
    });

    test('rejects use after close', () async {
      await chip.close();
      expect(() => chip.watchLineInfo([3]), throwsStateError);
      expect(() => chip.unwatchLineInfo(3), throwsStateError);
    });
  });

  group('teardown', () {
    test('close ends the stream and leaks no descriptors', () async {
      var done = false;
      final sub =
          chip.watchLineInfo([3]).listen(null, onDone: () => done = true);
      await pumpEventQueue();

      await chip.close();
      await pumpEventQueue();

      expect(done, isTrue, reason: 'closing the chip must end the stream');
      expect(kernel.openDescriptors, isZero);
      await sub.cancel();
    });

    test('cancelling the subscription releases the reader', () async {
      final sub = chip.watchLineInfo([3]).listen(null);
      await pumpEventQueue();
      await sub.cancel();
      await pumpEventQueue();

      // The chip itself is still usable; only the watcher went away.
      expect(() => chip.lineInfo(3), returnsNormally);
      await chip.close();
      expect(kernel.openDescriptors, isZero);
    });

    test('close is idempotent even with a watcher running', () async {
      chip.watchLineInfo([3]).listen(null);
      await pumpEventQueue();
      await chip.close();
      await chip.close();
      expect(chip.isClosed, isTrue);
    });
  });

  group('LineChangeKind', () {
    test('maps the kernel values', () {
      expect(LineChangeKind.fromValue(1), LineChangeKind.requested);
      expect(LineChangeKind.fromValue(2), LineChangeKind.released);
      expect(LineChangeKind.fromValue(3), LineChangeKind.reconfigured);
    });

    test('does not crash on a value a future kernel might add', () {
      // "Something changed" stays true whatever a fourth type turns out to
      // mean, and a running program must not die over it.
      expect(LineChangeKind.fromValue(99), LineChangeKind.reconfigured);
    });
  });

  group('LineInfoChanged', () {
    test('timestamp truncates nanoseconds to microseconds', () {
      const change = LineInfoChanged(
        kind: LineChangeKind.requested,
        info: GpioLineInfo(
          offset: 3,
          name: 'GPIO3',
          consumer: 'x',
          direction: LineDirection.input,
          used: true,
          activeLow: false,
          bias: Bias.asIs,
          drive: Drive.pushPull,
          edge: Edge.none,
          debouncePeriod: Duration.zero,
        ),
        timestampNs: 1234567,
      );
      expect(change.timestamp, const Duration(microseconds: 1234));
      expect(change.timestampNs, 1234567);
      expect(change.offset, 3);
    });
  });
}
