import Foundation

@main struct ExplainWorkspaceTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() {
            fputs("FAILED: \(name)\n", stderr)
            exit(1)
        }
        checks += 1
    }

    static func main() {
        let customFull = "SYNTHETIC_FULL: 코드 표기를 유지하세요."
        let customDelta = "SYNTHETIC_DELTA: 변경분만 설명하세요."

        // 1. Single-source final instruction & SHA-256 revision parity with LocalInstructionProfile
        let fullText = ExplainInstructionComposer.finalInstruction(
            mode: .full,
            fullTemplate: customFull,
            deltaTemplate: customDelta,
            outputStyleRules: CodeExplanation.outputStyleRules,
            defaultFull: CodeExplanation.defaultInstruction,
            defaultDelta: CodeExplanation.continueInstruction
        )
        check(fullText == CodeExplanation.effectiveInstruction(customFull),
              "full final instruction matches effectiveInstruction")
        let fullRev = ExplainInstructionComposer.revision(profileName: ExplainInstructionMode.full.profileName, text: fullText)
        let fullProfile = LocalInstructionProfile(name: .explain, text: fullText)
        check(fullProfile != nil && fullProfile?.revision == fullRev,
              "full revision matches LocalInstructionProfile")

        let deltaText = ExplainInstructionComposer.finalInstruction(
            mode: .delta,
            fullTemplate: customFull,
            deltaTemplate: customDelta,
            outputStyleRules: CodeExplanation.outputStyleRules,
            defaultFull: CodeExplanation.defaultInstruction,
            defaultDelta: CodeExplanation.continueInstruction
        )
        check(deltaText == fullText + "\n\n" + customDelta,
              "delta final instruction appends custom delta after outputStyleRules")
        let deltaRev = ExplainInstructionComposer.revision(profileName: ExplainInstructionMode.delta.profileName, text: deltaText)
        let deltaProfile = LocalInstructionProfile(name: .continue, text: deltaText)
        check(deltaProfile != nil && deltaProfile?.revision == deltaRev,
              "delta revision matches LocalInstructionProfile")

        let fallbackDelta = ExplainInstructionComposer.finalInstruction(
            mode: .delta,
            fullTemplate: "",
            deltaTemplate: "",
            outputStyleRules: CodeExplanation.outputStyleRules,
            defaultFull: CodeExplanation.defaultInstruction,
            defaultDelta: CodeExplanation.continueInstruction
        )
        check(fallbackDelta == CodeExplanation.effectiveInstruction("") + "\n\n" + CodeExplanation.continueInstruction,
              "empty templates fall back to defaults")

        // 2. InstructionShareState labels never claim '전송됨' or '생성 중'
        let grant = InstructionShareGrant(
            profileName: ExplainInstructionMode.full.profileName,
            peerPID: 4242,
            revision: fullRev,
            instructions: fullText,
            approvedAt: Date(timeIntervalSince1970: 1000),
            expiresAt: Date(timeIntervalSince1970: 1600)
        )
        let states: [InstructionShareState] = [
            .inactive,
            .allowed(grant),
            .revoked(.manual),
            .revoked(.edited),
            .revoked(.expired),
            .revoked(.terminated),
        ]
        for state in states {
            for mode in ExplainInstructionMode.allCases {
                let title = state.statusTitle(for: mode)
                let detail = state.statusDetail(for: mode)
                check(!title.contains("전송됨") && !detail.contains("전송됨"),
                      "share status never says 전송됨: \(title) | \(detail)")
                check(!title.contains("생성 중") && !detail.contains("생성 중"),
                      "share status never says 생성 중: \(title) | \(detail)")
            }
        }
        let allowedState = InstructionShareState.allowed(grant)
        check(allowedState.allows(mode: .full, revision: fullRev), "allowed state permits exact mode and revision")
        check(!allowedState.allows(mode: .delta, revision: fullRev), "allowed state denies other mode")
        check(!allowedState.allows(mode: .full, revision: deltaRev), "allowed state denies mismatched revision")

        // 3. ExplainDraftPayload validation
        check(ExplainDraftPayload(displayText: "   \n ", idempotencyKey: "k1") == nil, "blank displayText rejected")
        check(ExplainDraftPayload(displayText: "ok", spokenText: "   ", idempotencyKey: "k1") == nil, "blank spokenText rejected")
        check(ExplainDraftPayload(displayText: "ok\0bad", idempotencyKey: "k1") == nil, "NUL displayText rejected")
        check(ExplainDraftPayload(displayText: String(repeating: "a", count: ExplainDraftPayload.maxTextBytes + 1), idempotencyKey: "k1") == nil,
              "oversized displayText rejected")
        check(ExplainDraftPayload(displayText: "ok", idempotencyKey: "bad key") == nil, "invalid key rejected")
        check(ExplainDraftPayload(displayText: "ok", idempotencyKey: "k1", instructionRevision: "XYZ") == nil, "invalid revision rejected")

        // 4. Silent arrival, second arrival while editing, idempotency, dismiss
        var workspace = ExplainWorkspaceState()
        guard let p1 = ExplainDraftPayload(
            displayText: "as_frame 옵션을 켜면 데이터프레임을 반환합니다.",
            spokenText: "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다.",
            mode: .full,
            idempotencyKey: "req-1",
            instructionRevision: fullRev
        ) else {
            preconditionFailure("Expected valid payload")
        }
        let r1 = workspace.receive(p1, now: Date(timeIntervalSince1970: 10))
        check(r1.status == .accepted && r1.draft != nil, "first draft accepted")
        check(workspace.receivedDrafts.count == 1 && workspace.editor.isEmpty,
              "silent arrival leaves editor empty")

        // Retry exact same submission -> duplicate, single item
        let r1Retry = workspace.receive(p1, now: Date(timeIntervalSince1970: 11))
        check(r1Retry.status == .duplicate && workspace.receivedDrafts.count == 1,
              "identical retry returns duplicate and keeps single entry")

        // Same key with different payload -> conflict
        let p1Conflict = ExplainDraftPayload(displayText: "다른 문구", idempotencyKey: "req-1")!
        let r1Conflict = workspace.receive(p1Conflict)
        check(r1Conflict.status == .conflict && workspace.receivedDrafts.count == 1,
              "same key with different payload returns conflict")

        // Load draft 1 and start editing
        let d1ID = r1.draft!.id
        check(workspace.loadDraftIntoEditor(id: d1ID), "loaded draft 1")
        check(!workspace.editor.isSpokenStale && !workspace.editor.isDirty, "freshly loaded draft is synced and clean")
        workspace.editor.updateDisplayText("as_frame 옵션을 켜고 검증합니다.")
        check(workspace.editor.isDirty && workspace.editor.isSpokenStale, "editing display marks dirty and spoken stale")

        // Second arrival while user is editing must not touch editor
        let p2 = ExplainDraftPayload(
            displayText: "두 번째 도착 문구입니다.",
            spokenText: "두 번째 도착 낭독입니다.",
            mode: .delta,
            idempotencyKey: "req-2"
        )!
        let r2 = workspace.receive(p2, now: Date(timeIntervalSince1970: 20))
        check(r2.status == .accepted && workspace.receivedDrafts.count == 2, "second draft added to inbox")
        check(workspace.editor.displayText == "as_frame 옵션을 켜고 검증합니다.", "second arrival did not overwrite display editor")
        check(workspace.editor.spokenText == "애즈 프레임 옵션을 켜면 데이터프레임을 반환합니다.", "second arrival did not overwrite spoken editor")
        check(workspace.editor.isDirty, "second arrival preserved dirty editor state")

        // Dismiss draft 2 and retry req-2 -> still duplicate, does not re-appear
        workspace.dismissDraft(id: r2.draft!.id)
        check(workspace.receivedDrafts.count == 1, "dismissed draft removed from inbox")
        check(workspace.receive(p2).status == .duplicate && workspace.receivedDrafts.count == 1,
              "retrying dismissed draft in same session returns duplicate without re-inserting")
        workspace.resetSessionIdempotency()
        check(workspace.receive(p2).status == .accepted && workspace.receivedDrafts.count == 2,
              "resetting session idempotency permits new session submission")

        // 5. Display/spoken separation, NFC/NFD stale check, playback confirmation guard
        var editor = ExplainEditorState()
        let splitDraft = ReceivedExplainDraft(
            id: UUID(),
            idempotencyKey: "split",
            receivedAt: Date(),
            mode: .full,
            displayText: "caf\u{00E9} as_frame 설명",
            spokenText: "카페 애즈 프레임 설명",
            instructionRevision: nil
        )
        editor.load(splitDraft)
        check(!editor.isSpokenStale, "initial split draft is in sync")
        check(editor.playbackPlan() == .ready(
            spokenText: "카페 애즈 프레임 설명",
            displayText: "caf\u{00E9} as_frame 설명",
            usesSeparateSpoken: true
        ), "ready playback uses separate spoken and display strings")

        editor.updateDisplayText("cafe\u{0301} as_frame 설명") // canonically equal, different UTF-8 bytes
        check(editor.isSpokenStale, "byte-level NFC->NFD edit flags spoken stale")
        check(editor.playbackPlan(allowStaleSpoken: false) == .requiresConfirmation(
            displayText: "cafe\u{0301} as_frame 설명",
            staleSpokenText: "카페 애즈 프레임 설명"
        ), "stale playback blocked until confirmed")
        check(editor.displayOnlyPlaybackPlan() == .ready(
            spokenText: "cafe\u{0301} as_frame 설명",
            displayText: "cafe\u{0301} as_frame 설명",
            usesSeparateSpoken: false
        ), "display-only playback uses edited display text")
        check(editor.spokenText == "카페 애즈 프레임 설명" && editor.isSpokenStale,
              "display-only playback never mutates spokenText")
        check(editor.playbackPlan(allowStaleSpoken: true) == .ready(
            spokenText: "카페 애즈 프레임 설명",
            displayText: "cafe\u{0301} as_frame 설명",
            usesSeparateSpoken: true
        ), "explicit confirmation permits playing stale spoken text")

        editor.acknowledgeSpokenMatchesDisplay()
        check(!editor.isSpokenStale, "explicit acknowledgement clears stale flag")
        editor.updateDisplayText("새 문구")
        check(editor.isSpokenStale, "subsequent edit flags stale again")
        editor.updateSpokenText("새 낭독 문구")
        check(!editor.isSpokenStale, "editing spoken text re-syncs with current display text")
        editor.clearSpokenText()
        check(!editor.isSpokenStale && editor.playbackPlan() == .ready(
            spokenText: "새 문구",
            displayText: "새 문구",
            usesSeparateSpoken: false
        ), "clearing spoken falls back cleanly to display text")

        // Append behavior checks
        var appendEditor = ExplainEditorState()
        appendEditor.updateDisplayText("첫 문단")
        appendEditor.append(ReceivedExplainDraft(
            id: UUID(), idempotencyKey: "a1", receivedAt: Date(), mode: .delta,
            displayText: "둘째 as_frame", spokenText: "둘째 애즈 프레임", instructionRevision: nil
        ))
        check(!appendEditor.isSpokenStale && appendEditor.spokenText == "첫 문단\n\n둘째 애즈 프레임",
              "appending split draft onto display-only editor keeps full spoken text in sync")
        appendEditor.append(ReceivedExplainDraft(
            id: UUID(), idempotencyKey: "a2", receivedAt: Date(), mode: .delta,
            displayText: "셋째 문단", spokenText: nil, instructionRevision: nil
        ))
        check(appendEditor.isSpokenStale, "appending display-only draft onto split editor flags stale")

        // 6. LocalExplainDraftSocket JSON parsing
        let validJSON = Data("""
        {"display_text":"as_frame 출력","spoken_text":"애즈 프레임 출력","idempotency_key":"json-1","mode":"continue","instruction_revision":"\(deltaRev)"}
        """.utf8)
        let parsed = LocalExplainDraftSocket.parsePayload(from: validJSON)
        check(parsed?.mode == .delta && parsed?.spokenText == "애즈 프레임 출력", "valid JSON draft parsed")
        check(LocalExplainDraftSocket.parsePayload(from: Data("{\"display_text\":\"hi\",\"idempotency_key\":\"k\",\"extra\":1}".utf8)) == nil,
              "unknown key rejected")
        check(LocalExplainDraftSocket.parsePayload(from: Data("{\"display_text\":\"hi\",\"spoken_text\":null,\"idempotency_key\":\"k\"}".utf8)) == nil,
              "null spoken_text rejected")
        check(LocalExplainDraftSocket.parsePayload(from: Data("{\"display_text\":\"hi\",\"mode\":\"normalize\",\"idempotency_key\":\"k\"}".utf8)) == nil,
              "non-explain mode rejected")

        print("ExplainWorkspace tests passed (\(checks) checks).")
    }
}
