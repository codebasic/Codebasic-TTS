# 앱이 관리하는 TTS 지시를 로컬 MCP로 읽기 (설계안)

**상태:** Mac 작업트리 후보에 앱 메뉴와 별도 소켓을 구현했습니다. 실제 앱 설치·실행·설정 변경이나 저장된 사용자 지시 공유는 하지 않았습니다. 격리 Swift/Python 연결은 합성 지시로 확인했습니다.

## 결정

지시와 작업 흐름은 Codebasic TTS 앱에서 계속 관리합니다. 외부 폴더나 별도 에이전트 지시 파일로 옮기지 않습니다. 사용자가 앱에서 지시 공유를 따로 허용한 동안, 연결한 에이전트가 **읽기 전용 `get_tts_instructions(profile)`**로 필요한 프로필을 요청합니다. 앱은 조회에 모델이나 음성 제공자를 호출하지 않습니다. 기존 앱 자체의 해설·정규화·재생과 MCP `speak_text`는 그대로 둡니다.

MCP 표준의 `prompts/list`·`prompts/get`은 사용자가 메뉴 등에서 직접 선택하는 방식에 적합합니다. 에이전트가 명시적으로 조회하는 이번 요구에는 도구 호출이 맞습니다. 나중에 사용자 선택 방식이 필요하면 같은 프로필 조회 함수를 `prompts/get`에 연결할 수 있습니다. [MCP Prompts](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts), [MCP Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

## 프로필 내용과 경계

| `profile` | 앱에서 읽을 지시 | 포함하지 않을 것 |
| --- | --- | --- |
| `explain` | 앱에서 정한 `explainPrompt` 또는 기본 지시 + `CodeExplanation.effectiveInstruction`의 공통 해설 규칙 | 현재 코드, 스크린샷/OCR, 해설 기록, 이번 입력의 `explainHint` |
| `continue` | 위 해설 지시 + 기존 `continueInstruction`(바뀐 부분만 해설, 변경 없으면 정확히 `변경 없음`) | 앱이 저장한 이전·현재 코드 및 해설. 에이전트가 이미 갖고 있는 입력만 사용 |
| `normalize` | 앱에서 정한 `normalizePrompt` 또는 기본 대본 지시. 이 후보는 사전을 공유하지 않음. 나중에 별도로 표시하고 승인하는 경우만 검토 | `scriptHint`, 입력 원문, 사전 메모·ID |

응답은 `schema_version`, `profile`, `revision`, `instructions`만 반환합니다. `profile`은 위 세 값 중 하나만 받고 파일 이름·경로·임의 키는 받지 않습니다. API 키, 계정, 엔드포인트, 로컬 설정 원본, 백로그, 음성 기록과 캐시는 응답에 포함하지 않습니다. 도구 목록/초기화에는 공개 설명만 두고, 지시 본문을 시스템 메시지로 자동 추가하지 않습니다.

## 허용과 작업 흐름

1. 기존 **로컬 MCP 음성 입력 허용**만 켜면 기존대로 재생 요청만 받습니다. 별도 **로컬 MCP 지시 공유 (이번 실행)**는 기본 꺼짐입니다. 켤 때 프로필별로 전송될 실제 텍스트를 앱에서 미리 보여주고 명시적으로 승인받습니다. 실행 중 지시가 바뀌면 새 버전을 자동 공개하지 않고 다시 승인받습니다. 끄거나 앱을 종료하면 다음 조회가 차단됩니다.
2. 같은 macOS 로그인 계정 검사는 유지합니다. 같은 UID만으로 특정 에이전트가 승인됐다는 증거는 아닙니다. 지정 연결만 읽을 수 있어야 하므로, 앱에서 승인한 어댑터 PID와 프로세스 시작 시각을 macOS의 연결 상대 정보와 함께 비교합니다. 승인 상태는 메모리에만 있고 최대 10분입니다. 재시작된 도우미는 다시 승인해야 하며, 모델에 노출되는 인증 토큰이나 별도의 설정 파일은 없습니다. 다른 같은 계정 프로세스나 공유 해제 후 재사용은 실패해야 합니다.
3. 연결된 에이전트는 사용자 요청에 따라 필요한 프로필만 조회하고 그 작업에 적용합니다. 조회가 곧 합성은 아닙니다. 에이전트는 원하는 모델에서 지시를 적용해 최종 문장을 만든 다음, 사용자가 읽어 달라고 한 경우 별도 `speak_text`로 그 문장을 보냅니다. `변경 없음`은 재생하지 않습니다. 에이전트가 원격 모델이라면 조회한 지시가 그 모델 서비스로 갈 수 있으므로 이를 공유 화면에 알립니다. 이미 받은 지시를 앱에서 회수할 수는 없습니다.
4. 에이전트와 도우미는 Mac에서 같은 로그인 계정으로 실행해야 합니다. Windows가 현재 작업 화면이어도 Mac의 Unix 소켓을 Windows가 직접 읽는 구조는 아닙니다. 원격용 공개 포트나 웹 서비스는 추가하지 않습니다.

## 구현·검증 순서

1. `AppState`에서 기본값/사용자 지시와 공통 규칙을 조합하는 읽기 전용 프로필 함수를 만든다. `scriptInstruction()`을 그대로 노출하지 않는다. 이 함수는 현재 실행의 힌트를 사전·기본 규칙과 함께 포함한다. 저장 파일과 기존 파이프라인 호출 경로는 건드리지 않는다.
2. `AppDelegate`의 별도 앱 메뉴·미리보기·세션 승인과 `LocalSpeechSocket`의 허용된 읽기 분기를 추가한다. 기존 재생 메시지 형식은 유지한다. `scripts/mcp_speech.py`와 `s.sock`은 그대로 두고, 후보는 `scripts/mcp_tts_instructions.py`와 `i.sock`을 별도로 사용한다. 새 소켓에 JSON 프레임 상한과 기한을 따로 둔다. 큰 지시는 조용히 자르지 말고 오류를 반환한다.
3. 실제 사용자 설정 대신 합성 지시로 테스트한다. 기본 OFF, 재생만 ON, 연결 승인/취소, 미승인 동계정, 변경된 프로필 재승인, 잘못된 이름/길이, 그리고 응답에 민감 필드가 없는지 확인한다. 조회 횟수와 합성 호출을 분리해 조회 중 TTS·모델·파일 접근이 0인지 점검한다. `speak_text` 원문 보존과 Dock 닫기/종료 회귀도 함께 확인한다.
4. Mac 임시 홈의 Codex `app-server`에서 `get_tts_instructions` 도구 목록·허용/거부 조회를 검증한다. 모델 턴을 시작하지 않아도 검증할 수 있다. 접속 허용 여부와 범위가 확인되기 전에는 실제 사용자 지시를 연결하거나 음성 제공자에 요청하지 않는다.

## 격리 프로토콜 검증

앱 코드를 바꾸지 않고 아래 명령으로 프로토콜 초안을 확인할 수 있습니다.

```sh
/usr/bin/python3 -B -m unittest discover -s Tests -p test_mcp_instruction_profiles.py -v
```

`Tests/Fixtures/mcp_instruction_profiles.py`의 표준입출력 실행 모드는 합성 지시만 메모리에 두고, 승인 기능을 MCP에 노출하지 않아 조회가 항상 차단됩니다. 테스트 내부에서만 앱 사용자 승인·만료·철회를 흉내 냅니다. 토큰은 모델 인수와 응답에 나오지 않고 한 프로필만 허용합니다. 지시를 수정했다가 원래 값으로 되돌려도 다시 승인해야 합니다. 이 첫 단계의 순수 Python 테스트만으로는 실제 앱 UI·OS 피어를 확인할 수 없습니다.

## 후보의 수동 연결 (후보를 사용하기로 한 경우만)

아래 설정은 예시입니다. 이 작업에서는 실제 Codex 프로젝트 설정을 변경하지 않았습니다. Mac에서 신뢰하는 프로젝트의 `.codex/config.toml`에 추가할 때 사용합니다.

```toml
[mcp_servers.codebasic_tts_instructions]
command = "/usr/bin/python3"
args = ["-I", "-B", "/absolute/path/to/SelectedTextTTS/scripts/mcp_tts_instructions.py"]
[mcp_servers.codebasic_tts_instructions.env]
CODEBASIC_TTS_SIGNER_SHA1 = "TRUSTED_CERT_SHA1_40_HEX"

```

실제 연결은 [이미 신뢰한 공개 서명 인증서의 고정](mcp-codex-quick-test.md#실제-연결의-서명-고정)이 필요합니다. 도우미는 macOS가 제공한 소켓 상대의 audit token과 서명 요구사항을 검증한 뒤에만 요청을 보냅니다.

1. 직접 연결한 에이전트에게 읽을 프로필을 요청합니다. 처음 조회는 거절되고 연결 도우미 PID만 반환됩니다. 조회 도구는 음성 도구를 포함하지 않습니다.
2. 앱 메뉴 **로컬 MCP 지시 공유 (이번 실행)…**에서 해당 PID와 프로필 하나를 고릅니다. 미리 보기에서 정확히 전달될 지시를 확인하고 승인합니다. 이 과정에서 사전, 힌트, 과거 내용이나 비밀을 별도로 읽지 않습니다.
3. 같은 에이전트 세션에서 같은 프로필을 다시 조회합니다. 지시를 바꾸거나 앱 메뉴에서 끄면 재조회가 차단됩니다. 닫힌 창과 종료하지 않은 앱은 다르므로, 끝났으면 토글을 끄거나 `⌘Q`로 종료합니다.

실제 후보의 Swift Unix 소켓과 Python 표준입출력 어댑터만 사용해, 개인 설정 없이 확인하는 방법:

```sh
/usr/bin/python3 -I -B Tests/Fixtures/run_local_instruction_candidate.py
```

기대 결과: `default off; wrong signer rejected; approved exact revision only; other same-UID PID rejected; no speech tool; revoke works`. 임시 소켓이 샌드박스에서 막히면 승인된 로컬 터미널에서 실행해야 합니다. 이 테스트는 GUI를 조작하거나 설치본을 실행하지 않고, 별도의 검증용 Swift 실행 파일에서 합성 지시 한 문장만 사용합니다. 로그인된 에이전트의 모델 턴은 확인하지 않았습니다.

### 화면을 띄우지 않는 승인 흐름 확인

```sh
/usr/bin/python3 -I -B Tests/Fixtures/run_tts_instruction_approval_ui.py
```

이 테스트는 임시 프로필에서 실제 AppKit 메뉴 동작과 알림 객체를 사용합니다. 알림이 화면에 뜨기 전에 테스트가 버튼 응답을 돌려주므로 사용자 화면을 보거나 클릭하지 않습니다. 합성 프로필 전체 미리 보기, 취소 시 공유 안 함, 미리 보기 이후 수정 거부, 승인 시에만 소켓 생성, 메뉴에서 끄거나 앱 종료 콜백이 오면 소켓 제거를 확인합니다. 실제 화면 배치와 마우스 입력은 확인하지 않았습니다.
