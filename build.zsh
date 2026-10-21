set -eu
cd "${0:A:h}"
unset SWIFTPM_BUILD_DIR SWIFTPM_TESTS_MODULECACHE
if [[ -e .swiftpm ]]; then
  print -u2 'Remove .swiftpm before building: SwiftPM reads its configuration, which Git does not track.'
  exit 1
fi
build_args=(--package-path "$PWD" --scratch-path "$PWD/target/build" -c release --product pi-core-memories -Xswiftc -warnings-as-errors)
swift build "${build_args[@]}"
bin_path=$(swift build "${build_args[@]}" --show-bin-path)
test -f "$bin_path/pi-core-memories"
test -x "$bin_path/pi-core-memories"
test ! -L "$bin_path/pi-core-memories"
mkdir -p target/release
staged=$(mktemp target/release/.pi-core-memories.XXXXXX)
trap 'rm -f "$staged"' EXIT
cp -p "$bin_path/pi-core-memories" "$staged"
cmp "$bin_path/pi-core-memories" "$staged"
test -x "$staged"
mv -f "$staged" target/release/pi-core-memories
