# Codebasic TTS

<p align="center">
  <a href="https://github.com/sponsors/codebasic">
    <img alt="Sponsor" src="https://img.shields.io/badge/Sponsor-%E2%9D%A4-ea4aaa?logo=githubsponsors&logoColor=white" valign="middle">
  </a>
  <a href="https://github.com/codebasic/Codebasic-TTS/releases/latest">
    <img alt="Download" src="https://img.shields.io/badge/Download-v0.1.0-blue?logo=apple&logoColor=white" valign="middle">
  </a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-yellow.svg" valign="middle"></a>
</p>

macOS용 TTS 앱: **텍스트를 선택하고 단축키 한 번으로 AI 음성 읽기 + LLM 코드 해설**까지.

**개발 소스: v0.2.0 (빌드 2)** · [변경 기록](CHANGELOG.md). 최신 공개 다운로드는 **v0.1.0**이며, v0.2.0 앱 패키지는 아직 발행하지 않았습니다.

> 💖 **Codebasic TTS는 무료·오픈소스입니다.** 앱이 유용하다면 후원으로 개발을 응원해 주세요
> → [**GitHub Sponsors로 후원하기**](https://github.com/sponsors/codebasic) (금액·주기 자유)

- 아무 앱에서 텍스트 선택 → **⌃⌥⌘R** (또는 우클릭 → Services → "Codebasic TTS") → 곧바로 음성 재생
- 코드 선택 → **⌃⌥⌘E** → 연결된 LLM이 코드를 해설하고, 그 해설을 음성으로 읽어줌
- ElevenLabs(클라우드)와 로컬 Qwen3-TTS(MLX, 음성 클론) 중 선택해서 사용
- 문장 단위 스트리밍 재생, 문장별 음성 캐싱으로 반복 재생 즉시 반응
- TTS 스크립트를 다듬어주는 LLM 스크립트 편집기 + 용어집(glossary) 내장

| | |
|---|---|
| 플랫폼 | macOS 13.0+ (Apple Silicon 최적화, Intel 미검증) |
| 요구사항 | 릴리스 앱은 Xcode 불필요. 기존 플랜 연결은 Codex CLI 또는 Antigravity CLI, 로컬 음성은 Qwen3-TTS 서버 필요 |
| 라이선스 | MIT |
| 다운로드 | [Releases](../../releases/latest) 에서 `Codebasic-TTS.app.zip` |

---

## 빠른 시작 (일반 사용자)

1. [Releases](../../releases/latest)에서 **`Codebasic-TTS.app.zip`** 을 내려받아 압축 해제
2. `Codebasic TTS.app`을 **응용 프로그램 폴더 또는 ~/Applications로 이동**
3. 첫 실행: **우클릭 → "열기"** (개발자 서명이 없어 Gatekeeper 경고가 뜹니다 —
   브릿지 경고 없이 열리면 재부팅 후에도 다시 묻지 않습니다. 자세한 설명은 아래
   [보안 경고](#보안-경고-gatekeeper) 참고)
4. 관리 창의 **설정 → 음성**에서 엔진 연결:
   - **ElevenLabs**: [elevenlabs.io](https://elevenlabs.io)에서 발급한 API 키를 입력하고
     **저장 및 연결 확인** → 보이스와 합성 모델 선택 → **미리 듣기**
   - **로컬 Qwen3-TTS**(선택): [로컬 서버](#로컬-tts-사이드카-고급)를 실행한 뒤
     서버 주소를 입력하고 **연결 확인**. 서버에 등록된 참조 음성으로 재생합니다.
5. (전역 단축키를 쓸 경우) **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서
   `Codebasic TTS` 허용 — 앱이 이 화면을 자동으로 열어줍니다
6. 텍스트 선택 → **⌃⌥⌘R** → 재생 🎧

> 서비스 메뉴(우클릭 → Services)는 앱이 한 번 실행된 이후에 나타납니다.

## 사용법

| 동작 | 방법 |
|---|---|
| 선택 텍스트 읽기 | ⌃⌥⌘R 또는 우클릭 → Services → "Codebasic TTS" |
| 선택 코드 해설 후 읽기 | ⌃⌥⌘E 또는 Services → "Codebasic TTS: 코드 해설" |
| 일시정지 / 정지 | 재생 HUD 또는 메뉴 막대 아이콘 메뉴 |
| 스크립트 편집 · 해설 보기 | 메뉴 막대 아이콘 클릭 → 관리 창 |

## 설정

관리 창의 **설정**을 열고 왼쪽에서 항목을 선택합니다.

| 항목 | 설정 내용 |
|---|---|
| **음성** | 합성 엔진 연결, 보이스·모델 선택, 미리 듣기, 고급 음성 설정 |
| **AI 서비스** | 해설·대본 생성에 사용할 공급자, 연결 방식, 기본 모델 |
| **대본·발음** | 대본 다듬기, 발음 사전 |
| **재생·자막** | 재생 자막, 음성 캐시, 긴 대본의 합성 분할 기준 |
| **단축키** | 선택 텍스트 읽기·해설 단축키 안내, 손쉬운 사용 권한 확인 |

일반 설정은 자동 저장됩니다. API 키 입력과 AI 서비스 추가·편집은
**저장 및 연결 확인**을 눌러 반영합니다. 서비스 편집 중 **취소**하면 저장 전 변경은
반영되지 않으며, 삭제할 때는 별도 확인을 거칩니다.

### 음성 연결과 미리 듣기

| 엔진 | 특징 | 준비물 |
|---|---|---|
| ElevenLabs | 클라우드 음성 합성, 스트리밍 | API 키 |
| 로컬 Qwen3-TTS (MLX) | 오프라인 합성, 음성 클론 | Apple Silicon, 로컬 서버·모델 |

ElevenLabs는 연결 확인 후 **보이스**와 **합성 모델**을 선택합니다. 저장된 API 키는
**변경**으로 수정할 수 있으며, 안정성·유사도·스타일은 **고급 음성 설정**에 있습니다.
로컬 엔진의 참조 오디오와 전사 텍스트는 [사이드카 설정](#로컬-tts-사이드카-고급)에서 지정합니다.

**미리 듣기**에 최대 300자의 문장을 입력해 현재 음성을 확인하세요.
미리 듣기는 원문과 히스토리를 변경하지 않으며, ElevenLabs 사용 시 API 사용량이 발생합니다.

### AI 서비스 등록

1. **설정 → AI 서비스 → 서비스 추가**에서 공급자와 이름을 선택합니다.
2. API 키를 입력하거나, 지원되는 공급자는 **연결 방식 → 기존 플랜**을 선택합니다.
3. **저장 및 연결 확인**으로 서비스를 저장하고 모델을 조회합니다.
4. 필요하면 **조회한 모델에서 선택**으로 기본 모델을 지정하고 다시 저장합니다.
   실제 사용할 모델은 TTS·해설 화면에서도 선택할 수 있습니다.

| 공급자 프리셋 | 연결 방식 | 준비물 |
|---|---|---|
| OpenAI | API 키 / 기존 플랜 | OpenAI API 키 또는 Codex CLI와 사용 가능한 ChatGPT 계정 |
| Anthropic | API 키 | Anthropic API 키 |
| Google | API 키 / 기존 플랜 | Google API 키 또는 Antigravity CLI와 사용 가능한 Google 계정 |
| Ollama | 로컬 서버 | 실행 중인 Ollama 서버 주소, API 키는 선택 |
| OpenAI 호환 | 호환 API | 서버 주소와 해당 서비스의 인증 정보 |

프리셋은 기본 서버 주소를 채워 줍니다. OpenAI·Anthropic·Google의 API 주소는
**고급 연결 설정**에서, Ollama·OpenAI 호환 주소는 연결 정보에서 바로 편집합니다.
등록한 서비스는 **편집**에서 변경하거나 **이 서비스 사용**을 꺼 비활성화할 수 있습니다.
연결 방식을 바꿔도 저장된 API 키는 유지됩니다.

### 기존 플랜 연결

**OpenAI / ChatGPT**

1. [Codex CLI](https://developers.openai.com/codex/cli)를 설치합니다.
2. OpenAI 서비스의 **기존 플랜 → ChatGPT로 로그인**을 누르고 브라우저 인증을 완료합니다.
3. **저장 및 연결 확인**을 눌러 모델을 조회합니다.

공식 Codex App Server를 사용하며, 앱 전용 인증 저장소를 쓰므로 기존 CLI 로그인과
별도로 한 번 로그인해야 합니다.

**Google / Antigravity**

1. [Antigravity CLI](https://antigravity.google/docs/cli/install/)를 설치합니다.
   앱은 `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`의 `agy`를 찾습니다.
2. Google 서비스에서 **기존 플랜**을 선택하면 기존 로그인 상태를 확인합니다.
   연결이 필요하면 **Google 계정 연결**을 누르고 열린 터미널에서 로그인합니다.
3. 로그인 후 설정 화면으로 돌아오면 상태와 모델 목록이 자동 갱신됩니다.
   **연결 다시 확인**으로 재확인하거나, 확인 중에는 **확인 중지**를 누를 수 있습니다.
4. 연결 완료 후 로그인 터미널은 닫아도 됩니다. **저장 및 연결 확인**으로 서비스를 저장합니다.

Google 플랜 연결은 Gemini CLI가 아닌 **Antigravity CLI**를 사용합니다.
응답은 생성되는 대로 스트리밍 표시됩니다. 두 공급자의 플랜 연결 모두 구독 한도를 사용하며
인증·한도 오류가 나도 API로 자동 전환하지 않습니다. Google의 추가 AI 크레딧 사용도
비활성화합니다. 플랜 연결에는 온도 설정이 적용되지 않습니다.

### 이미지와 모델 선택

해설 화면에서는 **해설 모델**과 **비전 모델**을 각각 선택할 수 있습니다.

- **OpenAI 기존 플랜**: 이미지 입력을 지원합니다. 이미지 처리가 가능한 모델을 선택하세요.
- **Google 기존 플랜**: 현재 Antigravity CLI의 자동화 입력은 **텍스트 전용**이므로
  이미지를 처리할 수 없습니다. 이미지 요청은 오류를 표시하며 API로 자동 전환하지 않습니다.
- **API 연결**: 해당 공급자·모델이 이미지 입력을 지원해야 합니다.

예를 들어 해설 모델은 Google 플랜으로, 비전 모델은 OpenAI 플랜 또는 이미지 지원 API로
지정해 사용할 수 있습니다.

### 인증 정보 저장

API 키는 macOS 키체인이 아닌 앱 전용 Application Support 디렉토리에 저장되며
요청 대상 공급자에게만 전달됩니다. ChatGPT 로그인 정보는 공식 Codex가 앱 전용
`codex-plan` 디렉토리에서 관리합니다.

Google 연결 설정은 앱 전용 `antigravity-plan` 디렉토리에 저장하고 인증은 공식 CLI의
OS 키체인으로 관리합니다. 키체인 계정은 Antigravity와 공유될 수 있으며 앱은 토큰을
읽거나 복사하지 않습니다. 기존 Gemini CLI의 OAuth 파일은 사용하지 않습니다.

연동 참고: [Codex App Server](https://developers.openai.com/codex/app-server),
[Anthropic Messages API](https://platform.claude.com/docs/en/api/messages),
[Anthropic Models API](https://platform.claude.com/docs/en/api/models/list).

## 빌드 (소스에서)

Xcode 없이 **Command Line Tools만**으로 빌드됩니다.

```bash
xcode-select --install        # 최초 1회
git clone https://github.com/codebasic/Codebasic-TTS.git
cd Codebasic-TTS
./build.sh          # 빌드 → ~/Applications 설치 → Services 등록 → 실행
./build.sh build    # ./build 에만 빌드 (설치·등록 안 함)
./build.sh dev      # 빌드 후 이 터미널에서 포그라운드 실행 (로그 직접 출력)
./build.sh test     # 테스트 (텍스트 분할, 자막 정렬, AI 연결·스트리밍)
./build.sh logs     # 앱 통합 로그 스트리밍
./build.sh clean    # ./build 삭제
```

> Launch Services는 `~/Applications`와 `/Applications`만 확실히 스캔합니다.
> `./build/` 안에서 앱을 직접 실행하면 Services 메뉴에 안 나타날 수 있습니다.

### 안정적 서명 (Stable signing)

전역 단축키(⌃⌥⌘R/E)에 필요한 **손쉬운 사용** 권한은 서명 해시에 묶입니다. ad-hoc
서명은 재빌드할 때마다 권한이 조용히 풀립니다. 다음 명령으로 **자체 서명 인증서를 한
번만 만들어두면** (`Codebasic TTS Local`) 재빌드 후에도 권한이 유지됩니다.
`build.sh`는 이 인증서가 있으면 자동으로 사용하고, 없으면 ad-hoc으로 빌드합니다:

```bash
TMP="$(mktemp -d)"
cat > "$TMP/ext.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Codebasic TTS Local
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf"
# -passout 이 비어 있으면 Apple security import 가 MAC verification 오류로 실패합니다
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/id.p12" -passout pass:codebasic -name "Codebasic TTS Local"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P codebasic -A -T /usr/bin/codesign
rm -rf "$TMP"
```

(또는 키체인 접근 → 인증 지원 → **인증서 만들기…** → 이름 `Codebasic TTS Local`,
자체 서명 루트, 코드 서명.)

이 인증서는 *신뢰되지 않는* 인증서입니다(CSSMERR_TP_NOT_TRUSTED) — 그래도 괜찮습니다:
codesign은 서명에 사용하며, designated requirement가 안정적이기만 하면 TCC 권한이
유지됩니다. 이후:

```bash
./build.sh                                                # 인증서로 서명됨
tccutil reset Accessibility com.seongjoo.SelectedTextTTS  # 예전 ad-hoc 권한 1회 정리
# ⌃⌥⌘R 눌러서 손쉬운 사용 권한 부여 — 이후 재빌드에도 유지
```

## 보안 경고 (Gatekeeper)

이 앱은 Apple Developer ID 서명이 없어(비용 문제) 최초 실행 시
**"확인되지 않은 개발자"** 경고가 뜹니다. 개발자 서명·공증이 없는 것 외에 다른
제한은 없으며, 서명 자체는 유효합니다(`codesign --verify --deep` 통과).

- **우클릭 → 열기**로 실행하면 한 번 확인 후 정상 실행됩니다.
  이후 같은 위치에서는 다시 묻지 않습니다.
- 새 버전을 덮어쓴 뒤 다시 경고가 뜨면 같은 방법으로 열면 됩니다.
- 이 앱이 손쉬운 사용(전역 단축키), 마이크·키체인 접근 등의 권한을 요청하는 것은
  정상 동작이며, 요청 화면이 뜨면 시스템 설정에서 확인하고 허용하세요.

## 서비스 메뉴가 안 보일 때

1. `./build.sh` 다시 실행 (`lsregister -f` + `pbs -update/-flush` 재수행)
2. Services 노출이 잘 되는 앱에서 테스트 (TextEdit이 확실)
3. 수동 재등록:
   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
     -f ~/Applications/"Codebasic TTS.app"
   /System/Library/CoreServices/pbs -update
   ```
4. 최후: 로그아웃 후 다시 로그인. 위 단계 후에도 메뉴가 안 보이면 등록 이슈이지
   코드 문제가 아닙니다.

## 로컬 TTS 사이드카 (고급)

로컬 Qwen3-TTS 엔진은 별도 Python 프로세스(사이드카)가 `127.0.0.1` HTTP로 합성을
담당하고, Swift 앱이 여기에 붙는 구조입니다. 수동 구성이 필요한 경우:

```bash
cd Sidecar
uv venv --python 3.12 .venv
VIRTUAL_ENV=$PWD/.venv uv pip install -r requirements.txt
QWEN_TTS_REF_AUDIO=/path/to/ref.wav \
QWEN_TTS_REF_TEXT=/path/to/ref.txt \
.venv/bin/python server.py      # 기본 127.0.0.1:8765
```

- `GET /health` → `{status, model, sample_rate, ready}`
- `POST /tts` → `audio/wav` (body: `{"text": "...", "temperature"?, "speed"?}`)

음성 클론 테스트 CLI:

```bash
Sidecar/tts                      # REPL: 모델 1회 로드, 여러 문장 반복 테스트
Sidecar/tts "읽을 문장"           # 원샷: 합성 + 재생
Sidecar/tts "문장" -o out.wav    # 원샷: out.wav 에 저장
Sidecar/tts -m 4bit              # 양자화 선택 (4bit|5bit|6bit|8bit|bf16)
```

## 구조

```
Codebasic-TTS/
├── build.sh                        # swiftc 빌드 + 번들 조립 + Launch Services 등록
├── Resources/Info.plist            # LSUIElement + NSServices 정의
├── Sources/
│   ├── App/                        # 진입점, 메뉴 막대, 전역 단축키, 엔드포인트/시크릿
│   ├── Service/ServiceProvider.swift  # NSServices 핸들러 (read/explain)
│   ├── Core/                       # 문장 분할, 캐시, 큐 재생, 원문 정규화
│   ├── TTS/                        # TTSBackend 프로토콜 + ElevenLabs/로컬 Qwen3 백엔드
│   └── UI/                         # 관리 창, 설정, 스크립트 편집기, 플레이어 오버레이
├── Tests/                          # 단위 테스트, AI 연결·스트리밍 테스트와 CLI 픽스처
└── Sidecar/                        # 로컬 Qwen3-TTS(MLX) FastAPI 사이드카
```

## 진단 문서

[메모리 및 입력 지연 진단](docs/performance-diagnostics.md)

## 후원 💖

Codebasic TTS는 무료·오픈소스(MIT)로, 꾸준한 유지보수와 기능 개발로 계속 발전합니다.
앱이 유용하다면 후원으로 개발을 응원해 주세요 — 후원 금액·주기는 자유입니다.

<p align="center">
  <a href="https://github.com/sponsors/codebasic">
    <img alt="GitHub Sponsors로 후원하기" src="https://img.shields.io/badge/%E2%9D%A4%20GitHub%20Sponsors%EB%A1%9C%20%ED%9B%84%EC%9B%90%ED%95%98%EA%B8%B0-ea4aaa?style=for-the-badge&logo=githubsponsors&logoColor=white">
  </a>
</p>

## 라이선스

[MIT](LICENSE) © Codebasic
