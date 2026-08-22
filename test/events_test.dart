@TestOn('linux')
library;

import 'package:gpio/gpio.dart';
import 'package:gpio/gpio_testing.dart';
import 'package:gpio/src/events.dart';
import 'package:test/test.dart';

void main() {
  group('decoder', () {
    test('maps the kernel event id to an edge', () {
      final decoder = EventDecoder([4]);
      expect(
        decoder
            .decode(
              offset: 4,
              id: 1,
              timestampNanos: 1000,
              seqno: 1,
              lineSeqno: 1,
            )
            .single,
        isA<LineEdgeEvent>().having((e) => e.edge, 'edge', Edge.rising),
      );
      expect(
        decoder
            .decode(
              offset: 4,
              id: 2,
              timestampNanos: 2000,
              seqno: 2,
              lineSeqno: 2,
            )
            .single,
        isA<LineEdgeEvent>().having((e) => e.edge, 'edge', Edge.falling),
      );
    });

    test('a sequence gap becomes a drop report, before the next event', () {
      // Order matters: a listener should learn it missed something *before*
      // seeing what came after the gap, or it will misread the new value as
      // continuous with the old one.
      final decoder = EventDecoder([4])
        ..decode(
          offset: 4,
          id: 1,
          timestampNanos: 1000,
          seqno: 1,
          lineSeqno: 1,
        );

      final events = decoder.decode(
        offset: 4,
        id: 2,
        timestampNanos: 5000,
        seqno: 5,
        lineSeqno: 5,
      );

      expect(events, hasLength(2));
      expect(
        events.first,
        isA<LineEventsDropped>().having((e) => e.count, 'count', 3),
      );
      expect(events.last, isA<LineEdgeEvent>());
    });

    test('consecutive sequence numbers report no loss', () {
      final decoder = EventDecoder([4]);
      for (var i = 1; i <= 5; i++) {
        final events = decoder.decode(
          offset: 4,
          id: 1,
          timestampNanos: i * 1000,
          seqno: i,
          lineSeqno: i,
        );
        expect(events.whereType<LineEventsDropped>(), isEmpty);
      }
    });

    test('the first event never reports a drop', () {
      // There is no earlier sequence number to compare against, and a request
      // does not necessarily start at 1.
      final decoder = EventDecoder([4]);
      final events = decoder.decode(
        offset: 4,
        id: 1,
        timestampNanos: 1000,
        seqno: 99,
        lineSeqno: 99,
      );
      expect(events, hasLength(1));
      expect(events.single, isA<LineEdgeEvent>());
    });

    test("the timestamp is the kernel's, converted not recomputed", () {
      final decoder = EventDecoder([4]);
      final event = decoder
          .decode(
            offset: 4,
            id: 1,
            timestampNanos: 1234567000,
            seqno: 1,
            lineSeqno: 1,
          )
          .single as LineEdgeEvent;
      expect(event.timestamp, const Duration(microseconds: 1234567));
    });
  });

  group('stream', () {
    late FakeKernel kernel;
    late FakeChip fake;
    late GpioChip chip;

    setUp(() {
      fake = FakeChip(name: 'gpiochip0', label: 'fake', lineCount: 8);
      kernel = FakeKernel([fake]);
      chip = GpioChip.byLabel('fake', syscalls: kernel);
      addTearDown(chip.close);
    });

    test('delivers edges for a line that asked for them', () async {
      final request = chip.request(
        lines: [const LineConfig.input(3, edge: Edge.both)],
      );
      addTearDown(request.close);

      final received = <LineEvent>[];
      final subscription = request.events.listen(received.add);
      await pumpEventQueue();

      fake
        ..setLevel(3, value: true)
        ..setLevel(3, value: false);
      await pumpEventQueue();

      expect(received, hasLength(2));
      expect((received[0] as LineEdgeEvent).edge, Edge.rising);
      expect((received[1] as LineEdgeEvent).edge, Edge.falling);
      await subscription.cancel();
    });

    test('respects which edges were asked for', () async {
      final request = chip.request(
        lines: [const LineConfig.input(3, edge: Edge.rising)],
      );
      addTearDown(request.close);

      final received = <LineEvent>[];
      final subscription = request.events.listen(received.add);
      await pumpEventQueue();

      fake
        ..setLevel(3, value: true) // rising — wanted
        ..setLevel(3, value: false); // falling — not wanted
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect((received.single as LineEdgeEvent).edge, Edge.rising);
      await subscription.cancel();
    });

    test('activeLow flips which physical transition is a rising edge',
        () async {
      final request = chip.request(
        lines: [
          const LineConfig.input(3, edge: Edge.rising, activeLow: true),
        ],
      );
      addTearDown(request.close);

      final received = <LineEvent>[];
      final subscription = request.events.listen(received.add);
      await pumpEventQueue();

      // Pin goes LOW; with activeLow that is the line becoming active.
      fake
        ..setLevel(3, value: true)
        ..setLevel(3, value: false);
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect((received.single as LineEdgeEvent).edge, Edge.rising);
      await subscription.cancel();
    });

    test('a kernel FIFO overflow surfaces as a drop, not as silence', () async {
      // The differentiator. Every other Dart GPIO package loses these without
      // a word.
      final request = chip.request(
        lines: [const LineConfig.input(3, edge: Edge.both)],
      );
      addTearDown(request.close);

      final received = <LineEvent>[];
      final subscription = request.events.listen(received.add);
      await pumpEventQueue();

      fake.setLevel(3, value: true);
      await pumpEventQueue();

      kernel.dropNextEvents = 4; // the kernel discards four edges
      for (var i = 0; i < 4; i++) {
        fake.setLevel(3, value: i.isOdd);
      }
      await pumpEventQueue();

      fake.setLevel(3, value: false);
      await pumpEventQueue();

      final dropped = received.whereType<LineEventsDropped>().toList();
      expect(dropped, hasLength(1));
      expect(dropped.single.count, 4);
      expect(dropped.single.offset, 3);
      await subscription.cancel();
    });

    test('asking for events on a request with no edge detection explains why',
        () {
      final request = chip.request(lines: [const LineConfig.input(3)]);
      addTearDown(request.close);
      expect(
        () => request.events,
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('Edge.none')),
        ),
      );
    });

    test('closing the request ends the stream', () async {
      final request = chip.request(
        lines: [const LineConfig.input(3, edge: Edge.both)],
      );
      var done = false;
      request.events.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();

      await request.close();
      await pumpEventQueue();

      expect(done, isTrue);
    });

    test('cancelling the subscription releases the reader', () async {
      final request = chip.request(
        lines: [const LineConfig.input(3, edge: Edge.both)],
      );
      addTearDown(request.close);

      final subscription = request.events.listen((_) {});
      await pumpEventQueue();
      await subscription.cancel();
      await pumpEventQueue();

      // A second listen must work — the first one gave the reader back.
      final received = <LineEvent>[];
      final second = request.events.listen(received.add);
      await pumpEventQueue();
      fake.setLevel(3, value: true);
      await pumpEventQueue();

      expect(received, hasLength(1));
      await second.cancel();
    });
  });
}
