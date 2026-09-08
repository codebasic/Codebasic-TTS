---
name: codebasic-tts
description: 이 리포지토리 빌드·설정·서명·릴리스 작업 시 사용하는 프로젝트 스킬.
version: 1.0.0
author: Seongjoo (lseongjoo)
license: MIT
platforms: [macos]
---

# Codebasic TTS 프로젝트 스킬

이 리포지토리(Codebasic TTS — macOS 메뉴막 TTS 앱)에서 소스 수정, 설정 변경,
빌드, 릴리스를 할 에이전트를 위한 절차서. 상위 문서: `AGENTS.md`(워크스페이스
구조·gotchas), `README.md`(사용자 안내).

## 저장소 구조 주의

- 이 클론은 `main`이다. 파이프라인 브랜치(feature/pipeline-endpoints)는 별도
  클론(`SelectedTextTTS-wt-pipeline`)에 있어 여기 수정이 안 보인다.
- Xcode/SwiftPM 없음. `build.sh`가 `swiftc`로 `Sources/**`를 직접 컴파일해
  `.app` 번들을 손으로 조립한다. `swift build`/`swift test`는 무동작.
- 표시명 "Codebasic TTS", bundle id `com.seongjoo.SelectedTextTTS` —
  설치 경로·로그 서브시스템은 구 이름(SelectedTextTTS)을 쓴다. 혼동 금지.

## 설정 파일 (사용자 머신 기준)

위치: `~/Library/Application Support/Codebasic TTS/`

| 파일 | 내용 | 직접 편집 |
|---|---|---|
| `settings.json` | 백엔드·목소리·엔드포인트·프롬프트·glossary | 가능 (아래 규칙) |
| `eleven_key` | ElevenLabs API 키 (평문) | 가능 |
| `<endpoint-uuid>.key` | 엔드포인트별 LLM API 키 | 가능 |
| `cache/`, `norm_cache.json`, `backlog.json`, `tts-inbox/` | 캐시·대기열 | 금지 |

**settings.json 규칙** (`Sources/App/AppState.swift` saveSettings가 소스 of truth)
- API 키는 settings.json에 절대 없다 — `<endpoint_id>.key` 파일로만
  (`Sources/App/Secrets.swift`). settings.json에 키를 써넣으면 파서가 무시한다.
- `endpoints[]`: `{id, name, apiStyle: gemini|openAICompatible|ollama, baseURL,
  defaultModel, isEnabled}`. 역할별 모델은 `explainRoleModels` /
  `scriptRoleModels` / `visionRoleModels` (endpoint id → model 문자열).
- 역할-엔드포인트 매핑: `explainEndpointID` / `scriptEndpointID` /
  `visionEndpointID`.
- `backend`: `elevenlabs` 또는 로컬 Qwen3(`localBaseURL`, 기본
  `http://127.0.0.1:8765` — Sidecar/server.py).
- `normalizePrompt`, `explainPrompt`는 기본값과 다를 때만 저장된다 — 키를
  지우면 코드의 기본 프롬프트로 복귀.
- 편집 전 앱 종료 필수(실행 중이면 종료 시 덮어씀). 편집 전
  `cp settings.json settings.json.bak.$(date +%s)` 백업 관례.

## 빌드 / 테스트

```bash
./build.sh build   # 컴파일만 — 소스 수정 후 가장 빠른 확인. 완료 기준: exit 0
./build.sh test    # 단위 테스트(수동 check() 하니스). 완료 기준: 전부 통과
./build.sh dev     # 빌드 후 포그라운드 실행 (os_log → stderr)
./build.sh logs    # 통합 로그 스트리밍 (subsystem com.seongjoo.SelectedTextTTS)
./build.sh         # 무거움: 실행 중 앱 kill + ~/Applications 설치 + Services 재등록
```

- 새 pure-logic `Core/*.swift`는 `build.sh`의 `test` 대상 파일 목록에 **수동
  추가** — 안 하면 조용히 테스트에서 빠진다. 완료 기준: 새 파일이 목록에 있음.
- 앱 내 `print()`는 안 보임(LSUIElement). 로깅은 os_log로만.

## 서명 / 권한

- 안정적 자체 서명 인증서 `Codebasic TTS Local`(README "Stable signing"으로
  1회 생성). build.sh가 자동 감지. 이 인증서 서명은 재빌드해도 손쉬운 사용
  (전역 단축키) TCC 권한을 유지한다.
- ad-hoc 서명은 재빌드마다 권한 무효화 → `tccutil reset Accessibility
  com.seongjoo.SelectedTextTTS` 후 재허용 필요.
- Services 메뉴 미표출은 대부분 Launch Services 등록 문제: `./build.sh`
  재실행 → `lsregister -f` → 최후 로그아웃/로그인. 코드 버그가 아니다.

## 공개 릴리스 절차

1. `./build.sh build` 성공 + `codesign --verify --deep build/"Codebasic TTS.app"`
   (완료 기준: SIGNATURE_OK).
2. `Resources/Info.plist`의 `CFBundleShortVersionString` 갱신.
3. `cd build && ditto -c -k --sequesterRsrc --keepParent "Codebasic TTS.app"
   Codebasic-TTS.app.zip` — ditto 필수(Finder 압축은 Gatekeeper 검증을
   깨뜨릴 수 있음).
4. 번들 점검: `find "Codebasic TTS.app" -type f` — API 키·개인 음성 파일이
   하나도 없어야 업로드 진행. 완료 기준: 파일 목록에 번들 리소스만 있음.
5. 커밋·푸시 후 `gh release create vX.Y.Z build/Codebasic-TTS.app.zip
   --title ... --notes ...`.
6. 검증: `gh release view vX.Y.Z --json assets`로 에셋 확인 + 익명
   `curl -sIL <asset url>` 200 확인.

## 검증

- 소스 수정 작업: `./build.sh build` + `./build.sh test` 모두 통과가 최소 기준.
- 설정 편집 작업: 앱 재실행 후 설정이 반영됨 + `settings.json`이 유효 JSON.
- 릴리스 작업: 6번 항목의 익명 다운로드 200까지 확인해야 완료.
