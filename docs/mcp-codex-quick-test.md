# Mac에서 Codebasic TTS와 로컬 Codex MCP 확인

이 문서는 설치 없이 재생을 확인하는 방법과, 나중에 실제 앱을 연결하는 방법을 구분합니다. 확인한 Codex CLI 버전은 `0.169.1`입니다.

## 1. 앱 설치나 계정 연결 없이 확인

Mac에서 저장소 루트로 이동합니다. 아래 예시의 절대 경로를 본인의 체크아웃 경로로 바꾸세요. SwiftUI를 지원하는 도구 체인을 사용하세요. 이 후보는 macOS 26.5 SDK가 이미 설치된 환경에서 검증했습니다.

```sh
cd '/absolute/path/to/SelectedTextTTS'
./build.sh test
./build.sh build
```

`test`와 `build`는 앱을 설치하거나 실행하지 않습니다. 인자 없는 `./build.sh`는 앱을 설치·등록·실행합니다.

저장소에 포함된 격리 테스트로 발음 대본과 자막의 분리를 확인할 수 있습니다. 실제 제공자를 호출하지 않고 합성 입력만 검사합니다.

```sh
/usr/bin/python3 -B Tests/Fixtures/run_tts_pronunciation_case.py
```

이미 신뢰한 서명으로 빌드한 후보가 있으면, 별도 Swift 프로세스와 Python MCP 사이에서 합성 **지시**만 조회하는 테스트도 실행할 수 있습니다. 임시 Unix 소켓에만 연결합니다.

```sh
/usr/bin/python3 -I -B Tests/Fixtures/run_local_instruction_candidate.py
```

개발 중 로컬 Codex CLI의 임시 App Server로 캐시된 테스트 음성의 재생 종료와 소켓 정리를 확인했습니다. 그 실행용 임시 번들과 드라이버는 배포되는 저장소 파일이 아니므로 여기서 재현 명령으로 사용하지 않습니다. 로그인된 모델 턴이 음성을 실제 호출했다는 뜻도 아닙니다.

## 2. 실제 앱과 연결할 때만: 프로젝트별 수동 설정

위 검증에는 이 단계가 필요 없습니다. MCP 지원 버전의 Codebasic TTS가 이미 설치되어 실행 중인 상태에서만 사용하세요. 현재 설치 앱을 바꾸거나, 동일한 앱을 두 부 띄우거나, 전역 설정을 변경할 필요는 없습니다.

신뢰하는 Codex 프로젝트의 `.codex/config.toml`에 아래 표를 수동으로 추가합니다. 동일한 표가 이미 있으면 중복 추가하지 마세요. 이 형식은 별도 임시 프로젝트에서 설치된 CLI가 로드하는 것까지 확인했습니다. 현재 작업트리에 설정 파일을 쓰거나 신뢰 상태를 변경하지는 않았습니다.

```toml
[mcp_servers.codebasic_tts]
command = "/usr/bin/python3"
args = ["-I", "-B", "/absolute/path/to/SelectedTextTTS/scripts/mcp_speech.py"]
[mcp_servers.codebasic_tts.env]
CODEBASIC_TTS_SIGNER_SHA1 = "TRUSTED_CERT_SHA1_40_HEX"

```

프로젝트 루트에서 다음 명령으로 이름과 상태만 확인합니다. 이 목록 확인은 도구를 호출하지 않습니다.

```sh
codex mcp list --json | /usr/bin/python3 -c 'import json,sys; print([(s["name"],s["enabled"],s["transport"]["type"]) for s in json.load(sys.stdin) if s["name"]=="codebasic_tts"])'
```

예상: `[("codebasic_tts", True, "stdio")]`와 같은 한 행입니다. 새 Codex 세션에서 도구가 나타나야 하며, 로그인된 에이전트가 모델 턴 중 실제로 도구를 호출하는 것은 이번 검증 범위 밖입니다. Mac Mail, Messages, Gmail 연동은 이 경로에 쓰이지 않습니다.

실제로 읽힐 때만 Dock에서 Codebasic TTS를 열고, macOS 상단 **Codebasic TTS → 로컬 MCP 음성 입력 허용 (이번 실행)**을 켭니다. 기본은 꺼짐입니다. 앱은 창을 닫아도 켜져 있으므로 입력을 막으려면 같은 메뉴를 다시 눌러 끄거나 `⌘Q`로 종료하세요. 재생만 당장 멈추려면 **재생 중지**를 누릅니다. 실제 앱은 현재 선택된 음성 엔진을 사용하므로 클라우드 엔진에 요청하면 텍스트가 제공자에게 전송되고 크레딧이 들 수 있습니다. 무료 로컬 확인에는 1번만 사용하세요.

도구는 최종 일반 텍스트(`text`, UTF-8 최대 4,096바이트)와 요청별 `idempotency_key`를 받습니다. 접수 여부가 불명확하면 같은 키와 동일 텍스트를 써야 중복 재생을 피할 수 있습니다. 자세한 동작은 [로컬 MCP 음성 입력](mcp-speech.md)을 참고하세요.

### 실제 연결의 서명 고정

MCP 연결에는 이미 신뢰한 로컬 코드서명 인증서의 공개 지문이 필요합니다. 앱을 어떤 인증서로 빌드했는지 먼저 독립적으로 확인하세요. **이름이 같은 임의의 앱이나 소켓에서 지문을 가져와 신뢰하지 마세요.** 검증된 로컬 앱의 지정 요구사항에 `certificate leaf = H"…"`가 있다면 다음 명령으로 그 값을 확인할 수 있습니다.

```sh
APP="$PWD/build/Codebasic TTS.app"  # 본인이 신뢰하는 서명으로 빌드한 경로
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/codesign -dr - "$APP" 2>&1
```

`H"…"` 안의 인증서 지문 40자만 `CODEBASIC_TTS_SIGNER_SHA1`에 입력하세요. 비밀번호·API 키·코드 해시(CDHash)는 입력하지 않습니다. 애드혹 서명뿐이거나 독립적으로 신뢰한 지문을 확인할 수 없다면 MCP를 사용하지 마세요. 수동 TTS는 그대로 쓸 수 있습니다.

참고: [OpenAI Codex의 MCP 설정](https://learn.chatgpt.com/docs/extend/mcp?surface=cli), [Codex App Server 개발자 문서](https://developers.openai.com/codex/app-server).
