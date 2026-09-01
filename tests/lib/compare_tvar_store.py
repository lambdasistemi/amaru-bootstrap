#!/usr/bin/env python3
"""Compare a cardano-node tvar map's TxIn set with an ldb hex scan.

Owned copy of commit-auditor-cbor instrument
sha256 3933ad56e355360a108422efea9845abc8cb5248a5b9b29d0be6f06a72e735af
against candidate 1f676da. --drop-last-store-key is the required
negative control: the exact-set property must be able to fail.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


class DecodeError(Exception):
    """The narrow CBOR shape used by tables/tvar was not present."""


def head(data: bytes, pos: int) -> tuple[int, int, int]:
    if pos >= len(data):
        raise DecodeError(f"end of input at {pos}")
    initial = data[pos]
    major, additional = initial >> 5, initial & 0x1F
    pos += 1
    if additional < 24:
        return major, additional, pos
    widths = {24: 1, 25: 2, 26: 4, 27: 8}
    width = widths.get(additional)
    if width is None:
        raise DecodeError(f"unsupported additional info {additional} at {pos - 1}")
    end = pos + width
    if end > len(data):
        raise DecodeError(f"truncated length at {pos - 1}")
    return major, int.from_bytes(data[pos:end], "big"), end


def bytestring(data: bytes, pos: int) -> tuple[bytes, int]:
    major, length, pos = head(data, pos)
    if major != 2:
        raise DecodeError(f"expected byte string at {pos}, got major type {major}")
    end = pos + length
    if end > len(data):
        raise DecodeError(
            f"truncated byte string at {pos}: need {length}, have {len(data) - pos}"
        )
    return data[pos:end], end


def parse_tvar(path: Path) -> list[tuple[bytes, bytes]]:
    data = path.read_bytes()
    major, length, pos = head(data, 0)
    if (major, length) != (4, 1):
        raise DecodeError(f"expected array(1), got major={major} length={length}")
    major, length, pos = head(data, pos)
    if major != 5:
        raise DecodeError(f"expected definite map, got major={major}")
    pairs = []
    for _ in range(length):
        key, pos = bytestring(data, pos)
        value, pos = bytestring(data, pos)
        pairs.append((key, value))
    if pos != len(data):
        raise DecodeError(f"trailing bytes: decoded={pos} total={len(data)}")
    return pairs


def cbor_uint(value: int) -> bytes:
    if value < 24:
        return bytes([value])
    if value <= 0xFF:
        return bytes([0x18, value])
    if value <= 0xFFFF:
        return b"\x19" + value.to_bytes(2, "big")
    if value <= 0xFFFFFFFF:
        return b"\x1a" + value.to_bytes(4, "big")
    return b"\x1b" + value.to_bytes(8, "big")


def store_key(raw: bytes) -> bytes:
    if len(raw) != 34:
        raise DecodeError(f"expected 34-byte TxIn key, got {len(raw)}")
    index = int.from_bytes(raw[32:], "big")
    return b"utxo" + b"\x82\x58\x20" + raw[:32] + cbor_uint(index)


def parse_scan(path: Path) -> dict[bytes, bytes]:
    rows: dict[bytes, bytes] = {}
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if " ==> " not in line:
            continue
        key_text, value_text = line.split(" ==> ", 1)
        if not key_text.startswith("0x") or not value_text.startswith("0x"):
            raise DecodeError(f"non-hex ldb row at line {line_number}")
        rows[bytes.fromhex(key_text[2:])] = bytes.fromhex(value_text[2:])
    return rows


def digest(chunks: list[bytes]) -> str:
    h = hashlib.sha256()
    for chunk in chunks:
        h.update(len(chunk).to_bytes(8, "big"))
        h.update(chunk)
    return h.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("tvar", type=Path)
    parser.add_argument("scan", type=Path)
    parser.add_argument("--drop-last-store-key", action="store_true")
    args = parser.parse_args()

    pairs = parse_tvar(args.tvar)
    rows = parse_scan(args.scan)
    expected = {store_key(key): value for key, value in pairs}
    actual = {key: value for key, value in rows.items() if key.startswith(b"utxo")}
    if args.drop_last_store_key and actual:
        del actual[sorted(actual)[-1]]

    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    empty_values = sorted(key for key, value in actual.items() if not value)
    print(
        f"declared={len(pairs)} parsed={len(expected)} stored={len(actual)} "
        f"missing={len(missing)} extra={len(extra)} "
        f"empty_values={len(empty_values)}"
    )
    print(f"tvar_pair_sha256={digest([part for pair in pairs for part in pair])}")
    print(f"store_key_sha256={digest(sorted(actual))}")
    if missing:
        print("missing_keys=" + ",".join(key.hex() for key in missing))
    if extra:
        print("extra_keys=" + ",".join(key.hex() for key in extra))
    return 1 if missing or extra or empty_values else 0


if __name__ == "__main__":
    raise SystemExit(main())
