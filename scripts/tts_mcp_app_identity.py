"""Validate a live macOS socket peer against a user-pinned app signing anchor."""
import ctypes as C
from functools import lru_cache
import os
import re
import sys

BUNDLE_IDENTIFIER = "com.seongjoo.SelectedTextTTS"
PIN_ENV = "CODEBASIC_TTS_SIGNER_SHA1"
# Darwin sys/un.h: SOL_LOCAL, LOCAL_PEERTOKEN. audit_token_t contains eight UInt32.
SOL_LOCAL, LOCAL_PEERTOKEN, AUDIT_TOKEN_SIZE = 0, 6, 8 * C.sizeof(C.c_uint32)
UTF8_CF_ENCODING = 0x08000100


def certificate_requirement(fingerprint):
    if not isinstance(fingerprint, str) or re.fullmatch(r"[0-9a-fA-F]{40}", fingerprint) is None:
        return None
    return f'identifier "{BUNDLE_IDENTIFIER}" and certificate leaf = H"{fingerprint.lower()}"'


class DarwinSecurity:
    """Small CoreFoundation bridge. No Keychain reads, private keys, or path trust."""

    def __init__(self):
        foundation = self.cf = C.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        security = self.sec = C.CDLL("/System/Library/Frameworks/Security.framework/Security")
        void = C.c_void_p
        flags, status = C.c_uint32, C.c_int32
        self.audit_key = void.in_dll(security, "kSecGuestAttributeAudit")
        self.key_callbacks = C.addressof(C.c_byte.in_dll(foundation, "kCFTypeDictionaryKeyCallBacks"))
        self.value_callbacks = C.addressof(C.c_byte.in_dll(foundation, "kCFTypeDictionaryValueCallBacks"))
        foundation.CFDataCreate.argtypes = (void, void, C.c_long)
        foundation.CFDataCreate.restype = void
        foundation.CFStringCreateWithCString.argtypes = (void, C.c_char_p, C.c_uint32)
        foundation.CFStringCreateWithCString.restype = void
        foundation.CFDictionaryCreate.argtypes = (void, C.POINTER(void), C.POINTER(void), C.c_long, void, void)
        foundation.CFDictionaryCreate.restype = void
        foundation.CFRelease.argtypes = (void,)
        foundation.CFRelease.restype = None
        security.SecCodeCopyGuestWithAttributes.argtypes = (void, void, flags, C.POINTER(void))
        security.SecCodeCopyGuestWithAttributes.restype = status
        security.SecRequirementCreateWithString.argtypes = (void, flags, C.POINTER(void))
        security.SecRequirementCreateWithString.restype = status
        security.SecCodeCheckValidity.argtypes = (void, flags, void)
        security.SecCodeCheckValidity.restype = status

    def check_audit_token(self, token, requirement):
        cf, sec = self.cf, self.sec
        audit = cf.CFDataCreate(None, C.create_string_buffer(token), len(token))
        source = attrs = None
        code, requirement_ref = C.c_void_p(), C.c_void_p()
        try:
            if not audit:
                return False
            source = cf.CFStringCreateWithCString(None, requirement.encode("ascii"), UTF8_CF_ENCODING)
            if not source or sec.SecRequirementCreateWithString(source, 0, C.byref(requirement_ref)) != 0:
                return False
            values = (C.c_void_p * 1)(audit)
            attrs = cf.CFDictionaryCreate(None, C.byref(self.audit_key), values, 1,
                                          self.key_callbacks, self.value_callbacks)
            if not attrs or sec.SecCodeCopyGuestWithAttributes(None, attrs, 0, C.byref(code)) != 0:
                return False
            return sec.SecCodeCheckValidity(code, 0, requirement_ref) == 0
        finally:
            for item in (code, requirement_ref, attrs, source, audit):
                if item:
                    cf.CFRelease(item)


@lru_cache(maxsize=1)
def security():
    return DarwinSecurity()


def verified_app_peer(connection):
    """Fail closed before any speech input or profile selector is sent over IPC."""
    requirement = certificate_requirement(os.environ.get(PIN_ENV))
    if requirement is None or sys.platform != "darwin":
        return False
    try:
        token = connection.getsockopt(SOL_LOCAL, LOCAL_PEERTOKEN, AUDIT_TOKEN_SIZE)
        if not isinstance(token, bytes) or len(token) != AUDIT_TOKEN_SIZE or not any(token):
            return False
        return security().check_audit_token(token, requirement)
    except (OSError, ValueError, AttributeError, C.ArgumentError):
        return False
