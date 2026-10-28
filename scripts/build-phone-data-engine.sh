#!/usr/bin/env bash
# Builds PhoneDataEngine/ (Go) into PhoneDataEngine/build/LucinateWG.xcframework, for the iPhone and
# the simulator. xcodegen runs it before generating the project (preGenCommand in project.yml).
# It skips the build when the Go sources and the Go version haven't changed since the last one.
# Needs Go, see PhoneDataEngine/go.mod, and Xcode. The first build takes a few minutes.
set -euo pipefail

# The lowest iOS the app runs on. Keep it the same as the deployment target in project.yml.
minios=26.0

root=$(cd "$(dirname "$0")/.." && pwd)
src=$root/PhoneDataEngine
out=$src/build
stamp=$out/sources.sha

command -v go >/dev/null || { echo "Go is needed to build PhoneDataEngine/, see https://go.dev/dl" >&2; exit 1; }

# The Go version is in the hash too, so a Go upgrade (a fix in net, say) rebuilds. The tests aren't:
# they don't change the library.
hash=$({
    cat "$src/go.mod" "$src/go.sum" "$root/scripts/build-phone-data-engine.sh"
    find "$src" -maxdepth 1 -name '*.go' ! -name '*_test.go' | LC_ALL=C sort | xargs cat
    go version
} | shasum | cut -d' ' -f1)
if [[ -d $out/LucinateWG.xcframework && -f $stamp && $(cat "$stamp") == "$hash" ]]; then
    exit 0
fi

rm -rf "$out"
mkdir -p "$out"

# One static library per platform and architecture. Go's own iOS support covers the simulator too,
# as long as the C compiler targets it.
build() {
    local sdk=$1 arch=$2 target=$3 dir=$out/$1-$2
    local sysroot
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    mkdir -p "$dir"
    CGO_ENABLED=1 GOOS=ios GOARCH=$arch \
        CC="$(xcrun --sdk "$sdk" -f clang) -isysroot $sysroot -target $target" \
        CGO_CFLAGS="-isysroot $sysroot -target $target" \
        CGO_LDFLAGS="-isysroot $sysroot -target $target" \
        go -C "$src" build -buildmode=c-archive -trimpath -buildvcs=false -ldflags=-w -o "$dir/libLucinateWG.a" .
}

build iphoneos arm64 "arm64-apple-ios$minios"
build iphonesimulator arm64 "arm64-apple-ios$minios-simulator"
build iphonesimulator amd64 "x86_64-apple-ios$minios-simulator"

for platform in iphoneos iphonesimulator; do
    mkdir -p "$out/$platform/Headers"
    cp "$out/$platform-arm64/libLucinateWG.h" "$out/$platform/Headers/LucinateWG.h"
    cat > "$out/$platform/Headers/module.modulemap" <<'EOF'
module LucinateWG {
    header "LucinateWG.h"
    link "resolv"
    export *
}
EOF
done
cp "$out/iphoneos-arm64/libLucinateWG.a" "$out/iphoneos/"
lipo -create "$out/iphonesimulator-arm64/libLucinateWG.a" "$out/iphonesimulator-amd64/libLucinateWG.a" \
    -output "$out/iphonesimulator/libLucinateWG.a"

xcodebuild -create-xcframework \
    -library "$out/iphoneos/libLucinateWG.a" -headers "$out/iphoneos/Headers" \
    -library "$out/iphonesimulator/libLucinateWG.a" -headers "$out/iphonesimulator/Headers" \
    -output "$out/LucinateWG.xcframework" >/dev/null
rm -rf "$out"/iphoneos* "$out"/iphonesimulator*
echo "$hash" > "$stamp"
