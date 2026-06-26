import Foundation
import os

/// Centralised logging.
///
/// IMPORTANT (M1 smoke-test trap): an LSUIElement app launched via `open Foo.app`
/// has no terminal stdout, so plain `print()` goes nowhere. We log through the
/// unified logging system so output is visible regardless of how the app was
/// launched. Watch it live with:
///
///     log stream --predicate 'subsystem == "com.seongjoo.SelectedTextTTS"' --level debug
///
/// When you run the binary directly (`./build.sh dev`) the same messages also
/// appear on stderr because os_log mirrors to the console for foreground processes.
enum Log {
    static let subsystem = "com.seongjoo.SelectedTextTTS"
    static let service = Logger(subsystem: subsystem, category: "service")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let tts = Logger(subsystem: subsystem, category: "tts")
}
