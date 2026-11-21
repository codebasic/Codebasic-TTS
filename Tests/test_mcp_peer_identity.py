"""Defensive adapter tests: no data leaves an unverified socket."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import mcp_speech
import mcp_tts_instructions
import tts_mcp_app_identity as identity


class PeerIdentityTests(unittest.TestCase):
    def test_pin_is_fixed_identifier_and_hex_leaf_only(self):
        pin = "a0" * 20
        self.assertEqual(identity.certificate_requirement(pin.upper()),
                         f'identifier "{identity.BUNDLE_IDENTIFIER}" and certificate leaf = H"{pin}"')
        for bad in (None, "", "always", pin + "\n", pin[:-1], pin[:-1] + "x"):
            self.assertIsNone(identity.certificate_requirement(bad))

    @patch.object(identity.sys, "platform", "darwin")
    def test_missing_pin_or_missing_audit_token_does_not_invoke_security(self):
        sock = MagicMock()
        with patch.dict(os.environ, {}, clear=True), patch.object(identity, "security") as verify:
            self.assertFalse(identity.verified_app_peer(sock))
            sock.getsockopt.assert_not_called()
            verify.assert_not_called()
        with patch.dict(os.environ, {identity.PIN_ENV: "a" * 40}, clear=True), patch.object(identity, "security") as verify:
            for token in (b"", bytes(identity.AUDIT_TOKEN_SIZE), b"\x01" * (identity.AUDIT_TOKEN_SIZE - 1)):
                sock.getsockopt.return_value = token
                self.assertFalse(identity.verified_app_peer(sock))
            verify.assert_not_called()

    @patch.object(identity.sys, "platform", "darwin")
    def test_kernel_token_and_signing_requirement_are_both_checked(self):
        sock, token = MagicMock(), b"\x01" * identity.AUDIT_TOKEN_SIZE
        sock.getsockopt.return_value = token
        pin = "b" * 40
        with patch.dict(os.environ, {identity.PIN_ENV: pin}, clear=True), patch.object(identity, "security") as verify:
            verify.return_value.check_audit_token.return_value = False
            self.assertFalse(identity.verified_app_peer(sock))
            sock.getsockopt.assert_called_with(identity.SOL_LOCAL, identity.LOCAL_PEERTOKEN, identity.AUDIT_TOKEN_SIZE)
            verify.return_value.check_audit_token.assert_called_with(token, identity.certificate_requirement(pin))

    def test_speech_never_sends_text_before_app_authentication(self):
        connection = MagicMock()
        with patch.object(mcp_speech, "check_node", return_value=True), patch.object(mcp_speech, "same_uid", return_value=True), \
             patch.object(mcp_speech.socket, "socket") as factory, patch.object(mcp_speech, "exchange") as exchange:
            factory.return_value.__enter__.return_value = connection
            args = {"text": "synthetic only", "idempotency_key": "fixture"}
            self.assertEqual(mcp_speech.send_local(args, Path("/tmp/fixture.sock"), verify_peer=lambda _: False), "unsafe")
            exchange.assert_not_called()
            connection.sendall.assert_not_called()

    def test_instruction_adapter_never_sends_selector_before_app_authentication(self):
        connection = MagicMock()
        with patch.object(mcp_tts_instructions, "check_node", return_value=True), \
             patch.object(mcp_tts_instructions, "same_uid", return_value=True), \
             patch.object(mcp_tts_instructions, "verified_app_peer", return_value=False), \
             patch.object(mcp_tts_instructions.socket, "socket") as factory:
            factory.return_value.__enter__.return_value = connection
            self.assertIsNone(mcp_tts_instructions.get_profile("explain"))
            connection.sendall.assert_not_called()
