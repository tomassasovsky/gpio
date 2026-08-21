/// An in-memory kernel for testing code that talks to GPIO.
///
/// Import this instead of hand-mocking the syscall seam: it models the parts of
/// the character-device contract that matter — line ownership, `EBUSY`, masked
/// reads and writes, debounce attributes — so a test failure means the code
/// under test is wrong rather than that a mock drifted from reality.
library;

export 'src/testing/fake_kernel.dart';
