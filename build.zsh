set -eu
cd "${0:A:h}"
unset SWIFTPM_BUILD_DIR SWIFTPM_TESTS_MODULECACHE
build_args=(--package-path "$PWD" --scratch-path "$PWD/target/build" -c release --product pi-core-memories -Xswiftc -warnings-as-errors)
rm -f target/release/pi-core-memories
swift build "${build_args[@]}"
bin_path=$(swift build "${build_args[@]}" --show-bin-path)
test -f "$bin_path/pi-core-memories"
test -x "$bin_path/pi-core-memories"
test ! -L "$bin_path/pi-core-memories"
mkdir -p target/release
cp -p "$bin_path/pi-core-memories" target/release/pi-core-memories
cmp "$bin_path/pi-core-memories" target/release/pi-core-memories
test -x target/release/pi-core-memories
