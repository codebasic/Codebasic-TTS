import Foundation

@main struct AgentInstructionEditingTests {
    @MainActor static func main() throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = work.appendingPathComponent("preset-instructions.json")
        let original = "합성 지시 e\u{301}"
        let revised = "합성 지시 é"
        var buffer = AgentInstructionEditBuffer()
        let base = UUID()
        var edit = buffer.entry(for: "explain", expected: base, label: "첫 지시", text: original)
        precondition(!edit.isDirty)
        edit.text = revised
        buffer.update(edit, for: "explain")
        precondition(buffer.drafts["explain"]?.isDirty == true)
        var other = buffer.entry(for: "continue", expected: UUID(), label: "둘째 지시", text: "둘째")
        other.text = "수정 두 번째"
        buffer.update(other, for: "continue")
        precondition(AgentBytes.same(buffer.entry(for: "explain", expected: UUID(), label: "", text: "").text, revised))
        let beforeSave = try AgentPresetInstructions.read(at: store)
        precondition(beforeSave.isEmpty)
        let result = try AgentPresetInstructions.write(revised, for: "explain", expectedOverride: nil, at: store)
        precondition(AgentBytes.same(result["explain"]!, revised))
        let reloaded = try AgentPresetInstructions.read(at: store)
        precondition(AgentBytes.same(reloaded["explain"]!, revised))
        do {
            _ = try AgentPresetInstructions.write("다른 쓰기", for: "explain", expectedOverride: nil, at: store)
            preconditionFailure("stale save succeeded")
        } catch AgentCatalog.Failure.conflict {}
        buffer.revert("explain")
        precondition(buffer.drafts["explain"] == nil && buffer.drafts["continue"] != nil)
        buffer.revert("continue") // same operation after a confirmed deletion drops only that profile
        precondition(buffer.drafts.isEmpty)
        let corrupt = Data("untouched invalid data".utf8)
        try corrupt.write(to: store)
        do {
            _ = try AgentPresetInstructions.write("덮어쓰지 않음", for: "normalize", expectedOverride: nil, at: store)
            preconditionFailure("corruption overwritten")
        } catch {}
        let after = try Data(contentsOf: store)
        precondition(after == corrupt)
        let choices = [AgentInstructionChoice(id: "explain", label: "전체 해설"),
                       AgentInstructionChoice(id: "second", label: "짧은 해설"),
                       AgentInstructionChoice(id: "normalize", label: "정규화")]
        precondition(AgentInstructionChoice.matching(choices, query: "없는 이름").isEmpty)
        precondition(AgentInstructionChoice.matching(choices, query: "해설").map(\.id) == ["explain", "second"])
        precondition(AgentInstructionChoice.keyboardChoice(choices, query: "") == nil)
        precondition(AgentInstructionChoice.keyboardChoice(choices, query: "해설") == nil)
        precondition(AgentInstructionChoice.keyboardChoice(choices, query: " 짧은 ") == "second")
        print("Inline instruction editing: independent dirty buffers, byte-exact text, persisted-vs-unsaved, revert, deletion and stale write")
    }
}
