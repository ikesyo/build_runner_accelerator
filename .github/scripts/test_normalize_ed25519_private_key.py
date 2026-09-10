import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from normalize_ed25519_private_key import (
    KeyFormatError,
    _der_to_pem,
    _encode_length,
    _pem_to_der,
    normalize,
)


ALGORITHM_IDENTIFIER = bytes.fromhex("300506032b6570")
PRIVATE_KEY = b"\x04\x22\x04\x20" + bytes(range(32))
PUBLIC_KEY = b"\x81\x21\x00" + bytes(range(32, 64))


def _sequence(content: bytes) -> bytes:
    return b"\x30" + _encode_length(len(content)) + content


def _key(version: int, *, include_public_key: bool) -> bytes:
    content = bytes([0x02, 0x01, version]) + ALGORITHM_IDENTIFIER + PRIVATE_KEY
    if include_public_key:
        content += PUBLIC_KEY
    return _sequence(content)


class NormalizeTest(unittest.TestCase):
    def test_converts_implicit_public_key_field_to_v1(self) -> None:
        v2 = _key(1, include_public_key=True)
        v1 = _key(0, include_public_key=False)

        self.assertEqual(v1, _pem_to_der(normalize(_der_to_pem(v2))))

    def test_preserves_v1_key(self) -> None:
        v1 = _key(0, include_public_key=False)

        self.assertEqual(v1, _pem_to_der(normalize(_der_to_pem(v1))))

    def test_rejects_v2_without_public_key_field(self) -> None:
        invalid = _key(1, include_public_key=False)

        with self.assertRaisesRegex(
            KeyFormatError, "v2 key is missing its public-key field"
        ):
            normalize(_der_to_pem(invalid))

    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required")
    def test_normalized_key_is_accepted_by_openssl(self) -> None:
        normalized = normalize(_der_to_pem(_key(1, include_public_key=True)))

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "key.pem"
            path.write_bytes(normalized)
            subprocess.run(
                ["openssl", "pkey", "-in", str(path), "-noout"],
                check=True,
                capture_output=True,
            )


if __name__ == "__main__":
    unittest.main()
