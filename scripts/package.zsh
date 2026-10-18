#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" == --help ]]; then
  printf 'Usage: scripts/package.zsh [new-output-directory]\nBuild a relocatable Mac app and command runtime. No installation occurs.\n'
  exit 0
fi
if [[ $# -gt 1 ]]; then
  printf 'Expected at most one output directory.\n' >&2
  exit 2
fi
root=${0:A:h:h}
destination=${1:-"$root/.build/distribution"}
destination=${destination:A}
app="$destination/Core Memories.app"
runtime="$destination/lib/pi-core-memories/pi"
for target in "$app" "$destination/bin/pi-core-memories" "$destination/lib/pi-core-memories"; do
  if [[ -e "$target" || -L "$target" ]]; then
    printf 'Output already exists: %s. Choose a new directory.\n' "$target" >&2
    exit 1
  fi
done
swift build --package-path "$root" --configuration release -Xswiftc -warnings-as-errors
binaryDirectory=$(swift build --package-path "$root" --configuration release --show-bin-path)
version=$(/usr/bin/plutil -extract version raw -o - "$root/package.json")
minimumSystemVersion=$(swift package --package-path "$root" dump-package | /usr/bin/plutil -extract platforms.0.version raw -o - -)
mkdir -p "$destination/bin" "$runtime" "$app/Contents/MacOS" "$app/Contents/Resources/pi"
cp "$binaryDirectory/pi-core-memories" "$destination/bin/pi-core-memories"
cp "$binaryDirectory/pi-core-memories" "$app/Contents/MacOS/pi-core-memories"
cp "$binaryDirectory/CoreMemoriesApp" "$app/Contents/MacOS/CoreMemoriesApp"
for sourceFile in "$root/Integration/Pi/"*.ts; do
  [[ "$sourceFile" == *.test.ts ]] && continue
  cp "$sourceFile" "$runtime/"
  cp "$sourceFile" "$app/Contents/Resources/pi/"
done
cp "$root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$root/LICENSE" "$destination/lib/pi-core-memories/LICENSE"
chmod 755 "$destination/bin/pi-core-memories" "$app/Contents/MacOS/"*
/usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string org.pi-core-memories.app "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string 'Core Memories' "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string CoreMemoriesApp "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "$minimumSystemVersion" "$app/Contents/Info.plist"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$app/Contents/Info.plist"
printf 'App: %s\nCommand: %s\nRuntime: %s\n' "$app" "$destination/bin/pi-core-memories" "$runtime"
