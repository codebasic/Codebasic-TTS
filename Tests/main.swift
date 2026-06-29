// Standalone unit tests for the pure logic (TextSplitter, CrawlLayout) — compiled
// with the sources by `./build.sh test` (no Xcode/XCTest; those files only import
// Foundation / CoreGraphics).
import Foundation
import CoreGraphics

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)  \(detail())") }
}
func eq<T: Equatable>(_ name: String, _ a: T, _ b: T) { check(name, a == b, "got \(a), want \(b)") }

print("TextSplitter.sentences — token-internal '.' must not split")
eq("np.where", TextSplitter.sentences("이 코드는 np.where 함수를 씁니다.").count, 1)
eq("decimal 0.5", TextSplitter.sentences("학습률은 0.5 입니다.").count, 1)
eq("file.txt", TextSplitter.sentences("data.txt 를 읽습니다.").count, 1)
eq("self.w", TextSplitter.sentences("self.w 를 갱신합니다.").count, 1)
eq("two real sentences", TextSplitter.sentences("첫째입니다. 둘째입니다.").count, 2)
eq("single end period", TextSplitter.sentences("끝입니다.").count, 1)
eq("newline splits", TextSplitter.sentences("줄1\n줄2").count, 2)
eq("question/exclamation", TextSplitter.sentences("왜죠? 그렇군요! 끝.").count, 3)

print("TextSplitter.paragraphs / cleanInput")
eq("blank-line paragraphs", TextSplitter.paragraphs("문단1\n\n문단2").count, 2)
eq("cleanInput joins intra-para lines", TextSplitter.paragraphs(TextSplitter.cleanInput("a\nb\n\nc\nd")).count, 2)
eq("long paragraph splits at spaces", TextSplitter.paragraphs("aaaa bbbb cccc", maxChars: 6), ["aaaa", "bbbb", "cccc"])
eq("paragraph within budget stays whole", TextSplitter.paragraphs("짧은 문단입니다", maxChars: 700).count, 1)
eq("empty → none", TextSplitter.paragraphs("   \n  ").count, 0)
// dedupMathLeaks (via cleanInput): a math-only line repeated as the next line's prefix is a render leak
eq("cleanInput drops leaked math prefix", TextSplitter.cleanInput("k\nk는 상수입니다."), "k는 상수입니다.")
eq("cleanInput keeps non-prefix math", TextSplitter.cleanInput("x\ny는 다릅니다."), "x y는 다릅니다.")

print("TextSplitter.sentenceIndex — map overall progress onto the subtitle text")
let sents = ["가나다.", "라마바사.", "아자차카타파하."]   // lengths 4, 5, 8 (incl. period)
eq("start → 0", TextSplitter.sentenceIndex(at: 0, in: sents), 0)
eq("end → last", TextSplitter.sentenceIndex(at: 1, in: sents), 2)
eq("clamped below → 0", TextSplitter.sentenceIndex(at: -0.5, in: sents), 0)
eq("clamped above → last", TextSplitter.sentenceIndex(at: 2.0, in: sents), 2)
eq("single sentence → 0", TextSplitter.sentenceIndex(at: 0.9, in: ["하나뿐."]), 0)
eq("midpoint lands in 2nd (len-weighted)", TextSplitter.sentenceIndex(at: 0.4, in: sents), 1)

print("CrawlLayout.crawlOffset — content scrolls up; reading line at the anchor")
eq("progress 0 → anchor*viewport", CrawlLayout.crawlOffset(progress: 0, contentHeight: 1000, viewportHeight: 200, readingAnchor: 0.5), 100)
eq("progress 1 → fully scrolled", CrawlLayout.crawlOffset(progress: 1, contentHeight: 1000, viewportHeight: 200, readingAnchor: 0.5), -900)
eq("progress 0.5 → halfway", CrawlLayout.crawlOffset(progress: 0.5, contentHeight: 1000, viewportHeight: 200, readingAnchor: 0.5), -400)

print("CrawlLayout.clampOrigin — keep the HUD on screen")
let screen = CGRect(x: 0, y: 0, width: 500, height: 500)
let panel = CGSize(width: 100, height: 100)
eq("inside → unchanged", CrawlLayout.clampOrigin(CGPoint(x: 50, y: 50), size: panel, in: screen), CGPoint(x: 50, y: 50))
eq("past right → pinned", CrawlLayout.clampOrigin(CGPoint(x: 450, y: 50), size: panel, in: screen), CGPoint(x: 400, y: 50))
eq("below origin → pinned", CrawlLayout.clampOrigin(CGPoint(x: -10, y: -10), size: panel, in: screen), CGPoint(x: 0, y: 0))
eq("wider than screen → pinned to minX", CrawlLayout.clampOrigin(CGPoint(x: 30, y: 30), size: CGSize(width: 600, height: 100), in: screen), CGPoint(x: 0, y: 30))

if failures == 0 { print("\nAll tests passed.") } else { print("\n\(failures) test(s) FAILED."); exit(1) }
