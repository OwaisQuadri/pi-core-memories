#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == --help ]]; then
  printf 'Usage: scripts/package.zsh [new-output-directory]\nBuild a relocatable command runtime. No installation occurs.\n'
  exit 0
fi
if [[ $# -gt 1 ]]; then
  printf 'Expected at most one output directory.\n' >&2
  exit 2
fi
root=${0:A:h:h}
destination=${1:-"$root/.build/distribution"}
destination=${destination:A}
runtime="$destination/lib/pi-core-memories/pi"
for target in "$destination/bin/pi-core-memories" "$destination/lib/pi-core-memories"; do
  if [[ -e "$target" || -L "$target" ]]; then
    printf 'Output already exists: %s. Choose a new directory.\n' "$target" >&2
    exit 1
  fi
done
swift build --package-path "$root" --configuration release -Xswiftc -warnings-as-errors
binaryDirectory=$(swift build --package-path "$root" --configuration release --show-bin-path)
mkdir -p "$destination/bin" "$runtime"
cp "$binaryDirectory/pi-core-memories" "$destination/bin/pi-core-memories"
for sourceFile in "$root/Integration/Pi/"*.ts; do
  [[ "$sourceFile" == *.test.ts ]] && continue
  cp "$sourceFile" "$runtime/"
done
cp "$root/LICENSE" "$destination/lib/pi-core-memories/LICENSE"
chmod 755 "$destination/bin/pi-core-memories"
printf 'Command: %s\nRuntime: %s\n' "$destination/bin/pi-core-memories" "$runtime"
