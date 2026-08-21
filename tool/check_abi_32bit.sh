#!/usr/bin/env bash
#
# The Dart ABI test asserts struct sizes on whatever architecture it runs on.
# There is no 32-bit-ARM GitHub runner with a Dart SDK, so this checks the same
# proposition the cheap way: compile static assertions against the real
# <linux/gpio.h> with both a 32-bit and a 64-bit compiler. If the uAPI layout
# were width-dependent, the 32-bit build would fail.
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
} > "$src"

echo "Checking ${#pairs[@]} struct sizes from $test_file:"
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
