# Examples

Both take an optional chip label and line offset:

```sh
dart run example/blink.dart pinctrl-rp1 17
dart run example/button.dart pinctrl-rp1 17
```

Defaults are `pinctrl-rp1` (a Raspberry Pi 5) and line 17. Find your chip's
label with `gpiodetect`, or from Dart:

```dart
for (final chip in GpioChip.list()) {
  print('${chip.info.name}: ${chip.info.label} (${chip.info.lineCount} lines)');
  chip.close();
}
```

| example | what it shows |
|---|---|
| `blink.dart` | claiming an output, driving it, releasing it cleanly |
| `button.dart` | pull-up + `activeLow`, kernel debounce, the edge-event stream, and reacting to dropped edges |

Both need access to `/dev/gpiochip*` — see the udev rule in the top-level
README, or run them as root.
