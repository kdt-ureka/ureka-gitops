"""SMTP 비밀번호 변환이 AWS 공식 알고리즘과 같은지(형식·결정성) 확인한다. AWS 호출 없음."""
import base64
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "ses_secret", pathlib.Path(__file__).resolve().parents[2] / "scripts/ses/create-smtp-secret.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class SmtpPasswordTest(unittest.TestCase):
    def test_format_and_version_byte(self):
        pw = mod.smtp_password("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "ap-northeast-2")
        raw = base64.b64decode(pw)
        self.assertEqual(len(raw), 33)      # 버전 1바이트 + SHA256 32바이트
        self.assertEqual(raw[0], 0x04)

    def test_deterministic_and_region_bound(self):
        k = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        self.assertEqual(mod.smtp_password(k, "ap-northeast-2"), mod.smtp_password(k, "ap-northeast-2"))
        self.assertNotEqual(mod.smtp_password(k, "ap-northeast-2"), mod.smtp_password(k, "us-east-1"))


class SecretStateTest(unittest.TestCase):
    def _run(self, code, stderr):
        from unittest import mock
        res = mock.Mock(returncode=code, stderr=stderr)
        with mock.patch.object(mod.subprocess, "run", return_value=res):
            return mod.secret_state("s", "p", "r")

    def test_exists_absent_and_unknown(self):
        self.assertEqual(self._run(0, ""), "exists")
        self.assertEqual(self._run(254, "An error occurred (ResourceNotFoundException)"), "absent")
        with self.assertRaises(SystemExit):
            self._run(254, "An error occurred (AccessDeniedException)")


if __name__ == "__main__":
    unittest.main()
