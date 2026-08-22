#!/usr/bin/env bash
#
# The Dart ABI test asserts struct sizes on whatever architecture it runs on.
# There is no 32-bit-ARM GitHub runner with a Dart SDK, so this checks the same
# proposition the cheap way: compile static assertions against the real
# <linux/gpio.h> with both a 32-bit and a 64-bit compiler. If the uAPI layout
# were width-dependent, the 32-bit build would fail.
#
# Sizes alone are NOT enough. The _IOC request number encodes sizeof(), so a
# size-preserving change -- a future kernel spending some of a reserved
# padding[] array, or two same-width fields swapping -- yields an identical
# request number, passes a size check, and then silently misreads every field.
# So FIELD OFFSETS are asserted here too, along with the 8-byte ALIGNMENT that
# is the actual reason the layout is width-independent (see the block below).
#
# Note what -m32 does and does not prove: it is i386, not ARM EABI, and those
# differ in exactly the place that matters -- the natural alignment of a 64-bit
# scalar. The layout holds on ARM because of __aligned_u64 in the header, not
# because it holds on i386.
#
# The expected sizes are PARSED OUT OF THE DART TEST rather than duplicated, so
# the two cannot drift apart.
set -euo pipefail

cd "$(dirname "$0")/.."

test_file='test/abi_test.dart'
[ -f "$test_file" ] || { echo "missing $test_file" >&2; exit 1; }

# Pull `'struct_name': 123,` pairs out of the expected-sizes map.
mapfile -t pairs < <(
  sed -n "/const expected = <String, int>{/,/};/p" "$test_file" |
  sed -nE "s/^[[:space:]]*'([a-z0-9_]+)':[[:space:]]*([0-9]+),.*$/\1 \2/p"
)

[ "${#pairs[@]}" -gt 0 ] || { echo "parsed no sizes from $test_file" >&2; exit 1; }

src="$(mktemp -t gpio_abi_XXXXXX.c)"
trap 'rm -f "$src"' EXIT

{
  echo '#include <linux/gpio.h>'
  for pair in "${pairs[@]}"; do
    set -- $pair
    printf '_Static_assert(sizeof(struct %s)==%s, "%s size drift");\n' "$1" "$2" "$1"
  done
  # Field offsets, for the structs whose fields we actually read or write. A
  # size-preserving reordering passes every size check and every _IOC number.
  cat <<'ASSERTS'
#define O(t,f,n) _Static_assert(__builtin_offsetof(struct t,f)==n, #t "." #f " offset drift")
O(gpiochip_info, name, 0);
O(gpiochip_info, label, 32);
O(gpiochip_info, lines, 64);
O(gpio_v2_line_request, offsets, 0);
O(gpio_v2_line_request, consumer, 256);
O(gpio_v2_line_request, config, 288);
O(gpio_v2_line_request, num_lines, 560);
O(gpio_v2_line_request, event_buffer_size, 564);
O(gpio_v2_line_request, fd, 588);
O(gpio_v2_line_config, flags, 0);
O(gpio_v2_line_config, num_attrs, 8);
O(gpio_v2_line_config, attrs, 32);
O(gpio_v2_line_config_attribute, attr, 0);
O(gpio_v2_line_config_attribute, mask, 16);
O(gpio_v2_line_attribute, id, 0);
O(gpio_v2_line_values, bits, 0);
O(gpio_v2_line_values, mask, 8);
O(gpio_v2_line_info, name, 0);
O(gpio_v2_line_info, consumer, 32);
O(gpio_v2_line_info, offset, 64);
O(gpio_v2_line_info, num_attrs, 68);
O(gpio_v2_line_info, flags, 72);
O(gpio_v2_line_info, attrs, 80);
O(gpio_v2_line_event, timestamp_ns, 0);
O(gpio_v2_line_event, id, 8);
O(gpio_v2_line_event, offset, 12);
O(gpio_v2_line_event, seqno, 16);
O(gpio_v2_line_event, line_seqno, 20);
O(gpio_v2_line_info_changed, info, 0);
O(gpio_v2_line_info_changed, timestamp_ns, 256);
O(gpio_v2_line_info_changed, event_type, 264);
/* The reason any of this is width-independent in the first place.
 *
 * i386 aligns a bare `long long` to 4 bytes; ARM EABI aligns it to 8. If the
 * uAPI used plain __u64 the layouts would genuinely diverge, and an i386 pass
 * would prove nothing about ARM. It does not: linux/gpio.h declares every
 * 64-bit field __aligned_u64, forcing 8-byte alignment on EVERY ABI, precisely
 * so a 32-bit process and a 64-bit kernel agree.
 *
 * So assert the MECHANISM, not just its consequence. If __aligned_u64 is ever
 * dropped upstream, this fails on i386 immediately rather than waiting for
 * someone to run the suite on a real 32-bit ARM board. */
_Static_assert(_Alignof(struct gpio_v2_line_values) == 8,
    "gpio_v2_line_values lost its 8-byte alignment -- __aligned_u64 gone?");
_Static_assert(_Alignof(struct gpio_v2_line_attribute) == 8,
    "gpio_v2_line_attribute lost its 8-byte alignment");
_Static_assert(_Alignof(struct gpio_v2_line_event) == 8,
    "gpio_v2_line_event lost its 8-byte alignment");
ASSERTS
} > "$src"

echo "Checking ${#pairs[@]} struct sizes (from $test_file) + field offsets:"
for pair in "${pairs[@]}"; do echo "  $pair"; done

# asm/ headers live under the multiarch include dir on Debian/Ubuntu.
arch_include="/usr/include/$(uname -m)-linux-gnu"
inc=()
[ -d "$arch_include" ] && inc=(-I "$arch_include")

status=0
for width in 64 32; do
  if gcc "-m$width" "${inc[@]}" -c "$src" -o /dev/null 2>/dev/null; then
    echo "  -m$width: layout matches"
  else
    echo "  -m$width: LAYOUT MISMATCH" >&2
    gcc "-m$width" "${inc[@]}" -c "$src" -o /dev/null 2>&1 | head -20 >&2
    status=1
  fi
done

exit "$status"
