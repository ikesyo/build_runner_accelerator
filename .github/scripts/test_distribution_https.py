import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
from distribution_e2e import OPENSSL, create_https_certificates


@unittest.skipUnless(shutil.which(OPENSSL), 'OpenSSL is required')
class DistributionHttpsTest(unittest.TestCase):
    def test_ca_signed_server_certificate_has_server_auth_and_hostname_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ca, certificate, key = create_https_certificates(root)
            self.assertTrue(key.is_file())
            command = [OPENSSL, 'verify', '-x509_strict', '-CAfile', str(ca),
                       '-purpose', 'sslserver', '-verify_hostname', 'localhost', str(certificate)]
            valid = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            command[-2] = 'untrusted.example'
            wrong_hostname = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(wrong_hostname.returncode, 0)
            leaf = subprocess.check_output([OPENSSL, 'x509', '-in', str(certificate),
                                            '-noout', '-text'], text=True)
            self.assertIn('CA:FALSE', leaf)
            self.assertIn('TLS Web Server Authentication', leaf)
