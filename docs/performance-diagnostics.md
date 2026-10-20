# 메모리 및 입력 지연 진단

앱 전반의 메모리 증가와 입력 지연을 확인하기 위한 로그 수집·재현 절차입니다.
아래 명령은 저장소 루트에서 실행합니다. `APP_PID`와 `SERVER_PID`는 실제 프로세스 ID로 바꿉니다.

## 이미지 해설·자막 메모리 진단

`memory` 카테고리의 `[MEM-DIAG]` 로그는 앱 시작, 이미지 변경, 해설/이어쓰기/비전 시작·종료,
중지, 자막 전환 및 15초 주기에 기록됩니다. 원문·이미지 내용·인증 정보는 기록하지 않습니다.
빌드된 앱을 실행한 뒤 다음 명령으로 수집합니다 (기존 실행 앱은 자동 교체되지 않습니다).

```sh
/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.seongjoo.SelectedTextTTS" AND category == "memory"' | tee /tmp/tts-memory.log
```

1. 시작 후 30초 대기합니다. 같은 이미지 1장을 유지하고 해설 재생성을 10회 반복합니다.
2. 각 생성 완료 후 30초 대기합니다. `activeGenerations`가 0으로 돌아오는지 확인합니다.
   비전과 해설은 중첩되므로 진행 중 2 이상인 것은 정상일 수 있습니다.
3. 이미지를 모두 지우고 중지한 뒤 60초 대기합니다. `imageBytes=0`과 footprint 추이를 확인합니다.
4. 같은 해설을 자막 켜기/끄기로 각각 반복 재생하여 비교합니다.

`rssMiB`는 상주 메모리, `footprintMiB`는 압축 메모리를 포함하는 프로세스 메모리 부담입니다.
`imageBytes`는 첨부 PNG 크기이며 디코딩된 이미지/전송용 base64 크기는 포함하지 않습니다.
`backlogImageBytes`는 이슈 보관함 이미지의 논리적 총량이며 공유 저장소 때문에 다른 수치와 합산하면 안 됩니다.
`subtitleUTF8`와 `cachedSentences`는 자막 원문 크기와 문장 캐시 수입니다.
입력 크기와 작업 수가 같은데 완료 후 footprint가 반복적으로 증가하면 추가 할당 추적 대상입니다.
높은 수치 한 번이나 해제 직후 메모리가 줄지 않는 현상만으로 누수를 확정할 수 없습니다.
이 측정은 앱 프로세스만 대상으로 하며 별도 CLI/음성 서버 프로세스는 포함하지 않습니다.

전체 앱 진단도 같은 로그에 포함됩니다. `activities`는 실행 중 비동기 작업 또는 살아 있는
객체의 종류·개수·최장 경과 시간입니다. `instance`는 객체 생존 기간이므로 앱의 기본 창·재생기
각 1개는 정상입니다. RPC deadline은 응답이 끝나도 현재 구현상 최대 30초 남을 수 있습니다.
`activeGenerations`는 해설/비전/이어쓰기만 세므로 전체 작업 여부는 `activities`를 확인합니다.

- `normEntries/normTextBytes`: 정규화 캐시 항목·텍스트 크기. 이 캐시는 전체를 메모리에 로드하며 자동 개수 제한은 없습니다.
- `audioURLs/audioItems/audioObservers`: 재생 URL·실제 큐·알림 관찰자 수. 완료 후 일부 보관은 현재 동작이며 중지/새 재생 시 초기화되는지 비교합니다.
- `textUTF8/spokenChunks/timingValues`: 편집 내용·음성 청크·타이밍 배열의 크기.
- `windows/visibleWindows`, `urlCacheBytes`: 창 개수 및 공유 HTTP 캐시 사용량.
- `rpcBufferBytes/rpcPending`: 살아 있는 Codex RPC 객체의 수신 버퍼·대기 응답 합계.
- `audio.ready`: 합성 결과의 바이트 수. `compressedMiB/peakRSSMiB`: 압축 메모리·상주 메모리 최고치.

텍스트만 생성, 대본 생성/수정, 음성 합성/중지/앞뒤 이동, 미리 듣기, 설정·보관함 열고 닫기,
모델 연결 확인을 각각 동일 입력으로 10회 반복하고 작업 사이에 60초 쉬어 비교합니다.
정상 캐시 증가와 누수를 구분하기 위해 캐시 설정과 입력 길이도 재현 기록에 남겨 주세요.
15초 샘플 사이의 짧은 최고점이나 작업은 놓칠 수 있으며, 논리적 바이트 수는 실제 할당량과 다릅니다.

외부 CLI 및 로컬 음성 서버까지 확인하려면 앱 로그의 `pid`를 사용합니다.
별도로 실행한 로컬 음성 서버 PID는 두 번째 인자로 추가합니다.

```sh
python3 scripts/memory_watch.py APP_PID --samples 40 > /tmp/tts-process-memory.csv
# 별도 서버도 포함: python3 scripts/memory_watch.py APP_PID SERVER_PID > /tmp/tts-process-memory.csv
```

수집기는 15초마다 10분간 지정 프로세스와 발견한 자식의 RSS·CPU를 기록합니다.
명령행 인자·환경 변수·입력 내용은 수집하지 않습니다. 재부모화된 자식도 계속 추적하지만,
샘플 사이에 생성·종료된 프로세스는 놓칠 수 있고 PID 재사용 시 다른 프로세스가 섞일 수 있습니다.
원격 서버의 메모리나 macOS 전체 메모리 압력, 할당 스택은 이 로그에 포함되지 않습니다.
이 기록으로 증가 구간을 찾은 뒤 Instruments Allocations/Leaks로 할당 원인을 확인해야 누수를 확정할 수 있습니다.

## 입력 지연 진단

`responsiveness` 카테고리의 `[INPUT-DIAG]`는 15초마다 해당 구간의 입력·응답성 수치를 기록합니다.

```sh
/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.seongjoo.SelectedTextTTS" AND (category == "memory" OR category == "responsiveness")' | tee /tmp/tts-performance.log
```

- `keys/textChanges/markedChanges`: 앱 내부 키 이벤트·텍스트 변경 알림·IME 조합 중 변경 횟수.
  프로그램에 의한 텍스트 변경도 포함될 수 있습니다. 입력 문자, 키 코드, 클립보드는 읽거나 기록하지 않습니다.
- `maxTextUTF16`: 변경 알림을 받은 편집기의 최대 길이. 본문을 복사하지 않고 textStorage 길이를 읽습니다.
- `maxKeyQueueMS`: 이벤트 시각부터 앱 로컬 이벤트 처리 시점까지의 최대 지연.
- `maxMainTimerDelayMS/stallsOver100ms`: 앱이 활성 상태일 때 250ms 타이머의 추가 지연 및 100ms 이상 지연 횟수.
  실제 글자가 표시되기까지의 시간은 아니며, 멈춤이 풀려야 기록되고 시스템 부하·절전도 영향을 줄 수 있습니다.
- `work`: 모델 목록 계산·그룹화·설정 저장 호출 횟수와 최대 소요 시간.

같은 입력창에서 이미지 없음/있음, 재생 중지/자막 켠 재생/자막 끈 재생, 짧은 글/긴 글,
한글 조합/영문 입력을 각각 비교합니다. 지연을 느낀 시각과 입력창 이름을 함께 기록하면
메모리 상승 없이 입력만 느린 경우도 구분할 수 있습니다. 원인 스택이 필요하면 지연 중
`sample APP_PID 5 -file /tmp/tts-input-sample.txt`로 5초를 수집합니다.
