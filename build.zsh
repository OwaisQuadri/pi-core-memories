set -eu
cd "${0:A:h}"
unset SWIFTPM_BUILD_DIR SWIFTPM_TESTS_MODULECACHE
if [[ -e .swiftpm ]]; then
  print -u2 'Remove .swiftpm before building: SwiftPM reads its configuration, which Git does not track.'
  exit 1
fi
if [[ -L target || -L target/build ]]; then
  print -u2 'Refused symlinked target or scratch directory.'
  exit 1
fi
package_args=(--package-path "$PWD" --scratch-path "$PWD/target/build")
swift package "${package_args[@]}" clean
build_args=("${package_args[@]}" -c release --product pi-core-memories -Xswiftc -warnings-as-errors)
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
swift package "${package_args[@]}" clean
mv -f "$staged" target/release/pi-core-memories
