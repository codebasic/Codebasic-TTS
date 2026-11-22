# Codebasic TTS Agent 지시 카탈로그 · 서명 네이티브 MCP 서버 · 하네스 주도 연결

Codebasic TTS 앱과 번들 내 서명 네이티브 도우미(`Codebasic TTS.app/Contents/Helpers/codebasic-tts-agent-mcp`)가 **로컬 MCP 서버** 역할을 수행합니다. 외부 에이전트 하네스(Codex, Claude 등)가 이 도우미를 MCP 클라이언트로 실행하고, 사용자가 승인한 세션에 한해 지시 카탈로그를 조회하거나 대본 초안을 제출합니다.

## 핵심 경계

1. **에이전트 하네스가 통신을 시작합니다**:
   - 앱은 실행 중인 외부 에이전트 프로세스를 탐색하거나 먼저 연결하지 않습니다.
   - 사용자가 **에이전트 연결 대기 시작**을 누르면 앱은 최대 120초 동안 `pair.sock`을 엽니다.
   - 외부 에이전트 하네스가 `pair_tts_session` 도구를 호출하면, 서명 도우미가 앱의 코드 서명(`com.seongjoo.SelectedTextTTS` + 신뢰된 인증서)을 검증한 뒤 `pair.sock`에 노크합니다.
   - 앱도 OS 커널 `LOCAL_PEERTOKEN`으로 도우미의 서명(`com.seongjoo.SelectedTextTTS.agent-mcp` + 동일 인증서, 무권한 API 사용)과 UID·CDHash를 검증해 대기 목록에 올립니다. **연결 승인**을 누르기 전까지 어떤 읽기·받기 권한도 부여되지 않습니다.
2. **단일 고정 세션과 분리 임대**:
   - 동시에 **하나의 서명된 도우미 세션**만 고정(`pinned`)됩니다.
   - **지시문 조회(`i.sock`)**와 **대본 받기(`d.sock`)**는 별도 버튼·별도 소켓·별도 최대 10분 임대로 분리됩니다.
3. **로컬 지시 카탈로그 (`agent_instruction_catalog.json`)**:
   - 기존 기본 프로필(`explain`, `continue`, `normalize`)의 바이트와 개정 규칙(`tts-profile-v1`)은 유지하며, 별도의 원자적 파일 `agent_instruction_catalog.json`(`0600`)에 로컬 재사용 지시를 최대 **32개** 저장합니다.
   - 이름: 최대 **80자** 및 **UTF-8 96바이트**, 본문: 최대 **UTF-8 8,192바이트**, ID는 삭제 시 **tombstone**으로 영구 보존해 재사용하지 않습니다.
   - 공유 중인 지시문을 수정하면(수정 후 되돌려도) 기존 조회 허용이 즉시 **점착성 철회**됩니다. 삭제 시에도 즉시 철회됩니다.
4. **전달 증명(`delivery_proof`)과 지연 대본(`late_draft`) 및 속도 제한**:
   - 실제로 `get_agent_instruction`이 호출돼 지시가 전달될 때마다 해당 세션·피어·대상·개정 해시에 묶인 `delivery_proof`(최대 **32개**, 최대 **10분** 또는 세션/수신 종료 시 즉시 만료)가 발급됩니다. 조회 허용만 켜고 읽지 않으면 증명이 발급되지 않습니다.
   - 지연 대본 표시(`late_draft`, `instruction_target`, `instruction_revision`, `delivery_proof`)가 포함된 제출은 동일 피어 세션에 발급된 유효한 전달 증명이 일치할 때만 수락합니다.
   - 수신함 최대 **8건**(가득 차도 기존 항목 삭제 안 함), 중복 방지 **128건**, 프레임 상한 **100 KiB**, 속도 제한 **분당 6건 / 임대당 20건**.
5. **화면·음성 분리 해시 및 SSML 차단**:
   - 화면 글(`display`)과 음성 대본(`speech`)을 별도 SHA-256으로 해시하며, 처음 차이가 생길 때와 편집(수정 후 되돌림 포함) 후에는 명시적 확인 없이는 음성 대본을 재생하지 않습니다.
   - 원시 SSML(`<speak>`, `<break>`, `<prosody>` 등)과 인코딩된 SSML(`&lt;break/&gt;`, `%3Cspeak%3E`, `\u003cspeak\u003e`, 전각 `＜speak＞` 등)은 일반 `x < 5`·`List<String>` 문장을 막지 않으면서 합성 전 거부합니다.
