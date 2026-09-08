# Codebasic TTS

macOS용 TTS 앱: **텍스트를 선택하고 단축키 한 번으로 AI 음성 읽기 + LLM 코드 해설**까지.

- 아무 앱에서 텍스트 선택 → **⌃⌥⌘R** (또는 우클릭 → Services → "Codebasic TTS") → 곧바로 음성 재생
- 코드 선택 → **⌃⌥⌘E** → 연결된 LLM이 코드를 해설하고, 그 해설을 음성으로 읽어줌
- ElevenLabs(클라우드)와 로컬 Qwen3-TTS(MLX, 음성 클론) 중 선택해서 사용
- 문장 단위 스트리밍 재생, 문장별 음성 캐싱으로 반복 재생 즉시 반응
- TTS 스크립트를 다듬어주는 LLM 스크립트 편집기 + 용어집(glossary) 내장

| | |
|---|---|
| 플랫폼 | macOS 13.0+ (Apple Silicon 최적화, Intel 미검증) |
| 요구사항 | 없음 — Xcode/Python 사전 설치 불필요 (릴리스 앱 기준) |
| 라이선스 | MIT |
| 다운로드 | [Releases](../../releases/latest) 에서 `Codebasic-TTS.app.zip` |

---

## 빠른 시작 (일반 사용자)

1. [Releases](../../releases/latest)에서 **`Codebasic-TTS.app.zip`** 을 내려받아 압축 해제
2. `Codebasic TTS.app`을 **응용 프로그램 폴더 또는 ~/Applications로 이동**
3. 첫 실행: **우클릭 → "열기"** (개발자 서명이 없어 Gatekeeper 경고가 뜹니다 —
   브릿지 경고 없이 열리면 재부팅 후에도 다시 묻지 않습니다. 자세한 설명은 아래
   [보안 경고](#보안-경고-gatekeeper) 참고)
4. 메뉴 막대의 🔊 아이콘 → **설정**에서 사용할 엔진과 API 키 입력:
   - **ElevenLabs**: [elevenlabs.io](https://elevenlabs.io) 에서 발급한 API 키
     (무료 티어로도 충분히 써볼 수 있습니다)
   - **로컬 Qwen3-TTS**(선택): "로컬 엔진 설정" 버튼 — 첫 실행 시 Apple Silicon에
     Qwen3-TTS(1.7B, 6bit 양자화) 모델을 내려받고 Python 가상환경을 자동 구성합니다.
     인터넷 연결과 수 GB 디스크 여유가 필요하며, 이후에는 완전 오프라인 동작
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

**음성 엔진**

| 엔진 | 특징 | 준비물 |
|---|---|---|
| ElevenLabs | 고품질 클라우드 합성, 스트리밍 | API 키 |
| 로컬 Qwen3-TTS (MLX) | 오프라인, 내 목소리 클론 재생, 무료 | Apple Silicon, 최초 1회 모델 다운로드 |

로컬 엔진은 레퍼런스 음성(수 초 길이 녹음)으로 **voice cloning**을 지원합니다.
설정에서 레퍼런스 오디오/전사 텍스트를 지정하세요.

**텍스트 생성(LLM)** — 코드 해설(⌃⌥⌘E)과 스크립트 다듬기에는 OpenAI 호환 API,
Gemini, Ollama 등 **사용자가 직접 등록한 엔드포인트**를 사용합니다. 기본 제공
엔드포인트는 없으며, 설정 → 텍스트 생성에서 베이스 URL·모델·API 키를 추가하면 됩니다.
API 키는 macOS 키체인이 아닌 앱 전용 Application Support 디렉토리에 저장되고
네트워크로 전송되지 않습니다(요청 대상 엔드포인트 제외).

## 빌드 (소스에서)

Xcode 없이 **Command Line Tools만**으로 빌드됩니다.

```bash
xcode-select --install        # 최초 1회
git clone https://github.com/codebasic/Codebasic-TTS.git
cd Codebasic-TTS
./build.sh          # 빌드 → ~/Applications 설치 → Services 등록 → 실행
./build.sh build    # ./build 에만 빌드 (설치·등록 안 함)
./build.sh dev      # 빌드 후 이 터미널에서 포그라운드 실행 (로그 직접 출력)
./build.sh test     # 단위 테스트 (TextSplitter, 자막 정렬)
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
│   ├── UI/                         # 관리 창, 설정, 스크립트 편집기, 플레이어 오버레이
│   └── Tests/main.swift            # 단위 테스트
└── Sidecar/                        # 로컬 Qwen3-TTS(MLX) FastAPI 사이드카
```

## 라이선스

[MIT](LICENSE) © Codebasic
