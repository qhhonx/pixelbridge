#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="$project_dir/.build-cache"
mkdir -p "$cache"
fetch() {
  name=$1; url=$2; expected=$3; directory=$4
  archive="$cache/$name"
  if [ ! -f "$archive" ]; then
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 180 "$url" -o "$archive.tmp"
    mv "$archive.tmp" "$archive"
  fi
  actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
  [ "$actual" = "$expected" ] || { echo "Dependency checksum mismatch: $name" >&2; exit 1; }
  # Re-extract verified archives; never trust mutable extracted build tools.
  rm -rf "$cache/$directory"
  mkdir -p "$cache/$directory"
}
fetch exiftool-13.59.tar.gz https://codeload.github.com/exiftool/exiftool/tar.gz/refs/tags/13.59 87d3317882fdae9cb4dcfe57a96a378d0132ffc02c731315bf128b19ddcf7aac exiftool
 tar -xzf "$archive" --strip-components=1 -C "$cache/exiftool"
fetch Sparkle-2.9.6.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz 52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192 sparkle
 tar -xJf "$archive" -C "$cache/sparkle"
