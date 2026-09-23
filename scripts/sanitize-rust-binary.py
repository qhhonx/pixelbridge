"""Mask local home paths in an already stripped Rust binary, preserving byte offsets."""
import pathlib
import sys

binary = pathlib.Path(sys.argv[1])
prefix = (str(pathlib.Path.home()) + "/").encode()
replacement = b"/" + b"x" * (len(prefix) - 2) + b"/"
content = binary.read_bytes()
if prefix not in content:
    raise SystemExit("expected local path prefix was not found in Rust binary")
binary.write_bytes(content.replace(prefix, replacement))
