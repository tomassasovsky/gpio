import 'package:gpio/src/models.dart';
import 'package:meta/meta.dart';

/// Something that happened on a requested line.
///
/// A sealed hierarchy so `switch` over it is exhaustive: a caller cannot
/// silently forget to handle [LineEventsDropped], which is the whole point of
/// surfacing it.
@immutable
sealed class LineEvent {
  const LineEvent({required this.offset});

  /// The line this concerns.
  final int offset;
}

/// A transition the kernel detected on a line.
@immutable
final class LineEdgeEvent extends LineEvent {
  /// Creates an edge event.
  const LineEdgeEvent({
    required super.offset,
    required this.edge,
    required this.timestamp,
    required this.seqno,
    required this.lineSeqno,
  });

  /// Which way the line moved.
  final Edge edge;

  /// When the kernel saw it, on the request's [EventClock].
  ///
  /// Stamped in the interrupt handler, not on delivery — so scheduling delay
  /// between the kernel and your `listen` callback affects *when you hear about
  /// it*, never *what time it says*. That is what makes these timestamps usable
  /// for latency measurements.
  final Duration timestamp;

  /// Position in the sequence of events for the whole request.
  final int seqno;

  /// Position in the sequence of events for this line alone.
  final int lineSeqno;

  @override
  String toString() => 'LineEdgeEvent(line $offset, ${edge.name}, '
      '${timestamp.inMicroseconds}us, seq $seqno)';
}

/// The kernel dropped [count] events before the next one arrived.
///
/// The kernel buffers events per request in a fixed-size FIFO. If a burst
/// outruns the reader — a switch chattering, or an isolate starved by a long
/// synchronous task — the oldest events are discarded. Every other Dart GPIO
/// package loses them silently; the v2 ABI's sequence numbers make the loss
/// *provable*, so it is reported instead.
///
/// Seeing these means a real edge was missed. The usual fixes are a larger
/// `eventBufferSize` on the request, or a kernel-side `debounce` so chatter
/// never reaches the FIFO in the first place.
@immutable
final class LineEventsDropped extends LineEvent {
  /// Creates a dropped-event report.
  const LineEventsDropped({
    required super.offset,
    required this.count,
    required this.seqno,
  });

  /// How many events were lost.
  final int count;

  /// The sequence number of the event that revealed the gap.
  final int seqno;

  @override
  String toString() => 'LineEventsDropped(line $offset, $count lost)';
}

/// Turns raw `gpio_v2_line_event` records into [LineEvent]s, detecting gaps.
///
/// Kept separate from the isolate that reads them so the interesting part —
/// sequence-gap detection — is testable without any I/O at all.
class EventDecoder {
  /// Creates a decoder for a request holding [offsets].
  EventDecoder(this.offsets);

  /// The line offsets in request order, used to map event offsets back.
  final List<int> offsets;

  int? _lastSeqno;

  /// Decodes one raw event, returning the events to emit for it.
  ///
  /// Usually one. Two when a gap is detected: the drop report comes *first*, so
  /// a listener learns it missed something before it sees the event that
  /// followed the gap.
  List<LineEvent> decode({
    required int offset,
    required int id,
    required int timestampNanos,
    required int seqno,
    required int lineSeqno,
  }) {
    final events = <LineEvent>[];

    final previous = _lastSeqno;
    if (previous != null && seqno > previous + 1) {
      events.add(
        LineEventsDropped(
          offset: offset,
          count: seqno - previous - 1,
          seqno: seqno,
        ),
      );
    }
    _lastSeqno = seqno;

    events.add(
      LineEdgeEvent(
        offset: offset,
        // gpio_v2_line_event_id: 1 = RISING_EDGE, 2 = FALLING_EDGE.
        edge: id == 1 ? Edge.rising : Edge.falling,
        timestamp: Duration(microseconds: timestampNanos ~/ 1000),
        seqno: seqno,
        lineSeqno: lineSeqno,
      ),
    );
    return events;
  }
}
