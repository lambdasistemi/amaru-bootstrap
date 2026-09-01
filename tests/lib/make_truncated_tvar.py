#!/usr/bin/env python3
"""Create a tvar file truncated cleanly after N complete map pairs.

Owned copy of commit-auditor-cbor instrument
sha256 49aaac73bea004813f71506bd10b4437c62c20ef025bf53bdf4c37e835f2fc79
against candidate 1f676da. --append-hex 00 turns the cut into a
malformed non-EOF u8 key.
"""

from __future__ import annotations

import argparse
from pathlib import Path

from compare_tvar_store import DecodeError, bytestring, head


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--after", type=int, required=True)
    parser.add_argument("--append-hex", default="")
    args = parser.parse_args()

    data = args.source.read_bytes()
    major, outer_length, pos = head(data, 0)
    if (major, outer_length) != (4, 1):
        raise DecodeError("expected outer array(1)")
    major, declared, pos = head(data, pos)
    if major != 5 or args.after >= declared:
        raise DecodeError(
            f"need a definite map larger than truncation point: declared={declared}"
        )
    for _ in range(args.after):
        _, pos = bytestring(data, pos)
        _, pos = bytestring(data, pos)
    suffix = bytes.fromhex(args.append_hex)
    args.output.write_bytes(data[:pos] + suffix)
    print(
        f"declared={declared} kept={args.after} original_bytes={len(data)} "
        f"output_bytes={pos + len(suffix)} appended={suffix.hex() or 'none'}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
