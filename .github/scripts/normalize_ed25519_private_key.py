#!/usr/bin/env python3
"""Convert an Ed25519 RFC 5958 v2 key to a PKCS#8 v1 key.

Some key managers export Ed25519 private keys as OneAsymmetricKey v2, which
adds a precomputed public-key field. OpenSSL's file loader on the release
runner does not accept that field, while it does accept the equivalent v1
PrivateKeyInfo containing the private seed.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from pathlib import Path


PEM_BEGIN = b"-----BEGIN PRIVATE KEY-----"
PEM_END = b"-----END PRIVATE KEY-----"
ED25519_OID = b"+ep"
PUBLIC_KEY_TAG = 0x81  # [1] IMPLICIT BIT STRING in RFC 5958.


class KeyFormatError(ValueError):
    pass


def _read_tlv(data: bytes, offset: int) -> tuple[int, int, int, int]:
    start = offset
    if offset >= len(data):
        raise KeyFormatError("unexpected end of DER data")
    tag = data[offset]
    offset += 1
    if tag & 0x1F == 0x1F:
        raise KeyFormatError("high-tag-number DER is not supported")
    if offset >= len(data):
        raise KeyFormatError("missing DER length")
    length_byte = data[offset]
    offset += 1
    if length_byte & 0x80:
        length_size = length_byte & 0x7F
        if length_size == 0 or length_size > 4:
            raise KeyFormatError("invalid DER length")
        if offset + length_size > len(data):
            raise KeyFormatError("truncated DER length")
        length = int.from_bytes(data[offset : offset + length_size], "big")
        offset += length_size
    else:
        length = length_byte
    value_start = offset
    value_end = value_start + length
    if value_end > len(data):
        raise KeyFormatError("truncated DER value")
    return tag, start, value_start, value_end


def _children(data: bytes, start: int, end: int):
    offset = start
    while offset < end:
        tag, tlv_start, value_start, value_end = _read_tlv(data, offset)
        yield tag, tlv_start, value_start, value_end
        offset = value_end
    if offset != end:
        raise KeyFormatError("invalid DER child boundaries")


def _encode_length(length: int) -> bytes:
    if length < 0:
        raise ValueError("negative DER length")
    if length < 0x80:
        return bytes([length])
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(encoded)]) + encoded


def _pem_to_der(pem: bytes) -> bytes:
    normalized = pem.replace(b"\r\n", b"\n")
    # Accept a secret manager that serialized PEM newlines as literal "\\n".
    normalized = normalized.replace(b"\\r\\n", b"\n").replace(b"\\n", b"\n")
    lines = [
        line.strip() for line in normalized.splitlines() if line.strip()
    ]
    try:
        begin = lines.index(PEM_BEGIN)
        end = lines.index(PEM_END, begin + 1)
    except ValueError as error:
        raise KeyFormatError("expected an unencrypted PKCS#8 PEM") from error
    if begin != 0 or end != len(lines) - 1:
        raise KeyFormatError("unexpected data around PKCS#8 PEM")
    body = b"".join(lines[begin + 1 : end])
    try:
        return base64.b64decode(body, validate=True)
    except binascii.Error as error:
        raise KeyFormatError("invalid PKCS#8 PEM Base64") from error


def _der_to_pem(der: bytes) -> bytes:
    encoded = base64.b64encode(der)
    lines = [
        encoded[index : index + 64] for index in range(0, len(encoded), 64)
    ]
    return b"\n".join([PEM_BEGIN, *lines, PEM_END, b""])


def normalize(pem: bytes) -> bytes:
    der = _pem_to_der(pem)
    outer_tag, _, outer_start, outer_end = _read_tlv(der, 0)
    if outer_tag != 0x30 or outer_end != len(der):
        raise KeyFormatError("expected one DER SEQUENCE")
    fields = list(_children(der, outer_start, outer_end))
    if len(fields) < 3 or fields[0][0] != 0x02:
        raise KeyFormatError("invalid OneAsymmetricKey structure")

    version = int.from_bytes(der[fields[0][2] : fields[0][3]], "big")
    if version not in (0, 1):
        raise KeyFormatError(f"unsupported OneAsymmetricKey version: {version}")

    algorithm = fields[1]
    if algorithm[0] != 0x30:
        raise KeyFormatError("missing private-key algorithm")
    algorithm_fields = list(_children(der, algorithm[2], algorithm[3]))
    if (
        not algorithm_fields
        or algorithm_fields[0][0] != 0x06
        or der[algorithm_fields[0][2] : algorithm_fields[0][3]] != ED25519_OID
    ):
        raise KeyFormatError("expected an Ed25519 private key")
    if fields[2][0] != 0x04:
        raise KeyFormatError("missing private-key value")

    public_key_fields = [
        field for field in fields[3:] if field[0] == PUBLIC_KEY_TAG
    ]
    if len(public_key_fields) > 1:
        raise KeyFormatError("multiple public-key fields")
    if version == 0 and public_key_fields:
        raise KeyFormatError("v1 key unexpectedly contains a public-key field")
    if version == 1 and not public_key_fields:
        raise KeyFormatError("v2 key is missing its public-key field")

    if version == 0:
        return _der_to_pem(der)

    version_field = b"\x02\x01\x00"
    content = version_field + b"".join(
        der[field[1] : field[3]]
        for field in fields[1:]
        if field[0] != PUBLIC_KEY_TAG
    )
    normalized_der = b"\x30" + _encode_length(len(content)) + content
    return _der_to_pem(normalized_der)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_bytes(normalize(args.input.read_bytes()))


if __name__ == "__main__":
    main()
