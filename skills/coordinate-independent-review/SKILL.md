---
name: coordinate-independent-review
description: Coordinate independent software reviews for a pinned HEAD and base, assign independent reviewers from the two other provider families and a separate senior reviewer from the implementation owner's family, and synthesize isolated verification evidence for integration or release decisions. Use for multi-agent review, re-review, and promotion readiness.
---

# 독립 리뷰 조정

## 배정

작업 이슈에서 실제 구현 책임자 계열을 확인합니다. 대화 UI만 바뀌면 배정을 유지합니다. 구현 책임자 계열이 바뀌면 다음 회차에서 세 자리를 다시 배정합니다.

| 구현 책임자 | 다른 두 계열의 독립 검토 | 주 계열 상위 모델의 별도 검토 |
| --- | --- | --- |
| OpenAI (ChatGPT/Codex) | Anthropic, Google | OpenAI 상위 모델 |
| Anthropic (Claude) | OpenAI, Google | Anthropic 상위 모델 |
| Google (Antigravity) | OpenAI, Anthropic | Google 상위 모델 |

괄호는 하네스 예시입니다. 여러 계열의 모델을 제공하는 하네스에서는 이번 작업에서 실제 구현을 맡은 계열을 확인합니다. 계열을 확인할 수 없으면 배정을 미확인으로 기록합니다.

세 검토 세션을 구현과 서로에게서 분리합니다. 프로젝트별 필수 역할도 적용합니다. 프로젝트가 명시적으로 승인한 모델·하네스·자료·전송 대상만 사용합니다. 공통 모델 ID는 지정하지 않습니다. 승인 또는 가용성이 없으면 미충족, 증거가 부족하면 미확인으로 기록합니다. 임의 실행과 자동 대체를 금지합니다. 요청한 모델과 관찰된 모델·하네스를 구분해 기록합니다.

## 검토와 판단

1. [브리프](references/review-brief.md)에 이슈 목표, 정확한 HEAD·기준 SHA, 읽기 전용 소스·diff·허용 자료와 보고 형식을 고정합니다. 각 검토자에게 같은 중립 브리프를 보내고 첫 의견이 확정될 때까지 구현자의 결론이나 다른 의견을 공유하지 않습니다. 대상 코드 실행과 파일 변경은 별도 역할에 한합니다. 비밀·운영 자료는 제외합니다. 5관점(소프트웨어 공학·UI/UX·최종 사용자·방어적 보안·배포)은 검토 범위입니다. 적용 범위는 제공자 배정과 독립이며 별도 2축 프리셋은 자체 정의를 따릅니다.
2. 첫 회차, 기준 SHA 변경, 이력이 이어지지 않거나 불명확한 경우, 구현 책임자 계열 변경에는 전체 diff를 검토합니다. 이력이 이어지는 같은 기준에서는 직전 회차에서 같은 역할로 검토를 마친 동일 검토자는 변경분과 기존 지적을 재검토할 수 있습니다. 이전 첫 보고서와 새 조합의 독립 증분 보고서를 함께 인용하고, 새 보고 전에는 검토자 자신의 이전 의견만 제공합니다. 바뀐 역할이나 누락된 범위는 전체를 확인합니다. HEAD·기준 SHA가 바뀌면 새 조합으로 검토·검증하고 기존 근거는 원래 조합에 귀속합니다.
3. 별도 실행 담당이 승인된 격리 환경의 같은 HEAD·기준 SHA에서 합성 자료로 필요한 결과를 확인합니다. 실제 자료나 환경에는 별도 승인이 필요합니다. PR 등록 전에 실행할 수 있는 격리 경로를 사용합니다. [증거 양식](references/evidence.md)에 실행 환경·절차·결과와 정적 판단·미확인을 구분해 기록합니다. 통합 판단 담당은 구현과 분리하고 첫 보고가 확정된 뒤 근거와 이견을 확인합니다. 자동 리뷰는 검토한 HEAD를 확인한 뒤 보조 증거로만 사용합니다. 필수 독립 의견이나 실행 증거를 대체하지 않습니다.
4. 검토판과 릴리스 준비도를 따로 판단합니다. 알려진 필수 조건 미충족은 `blocked`, 필수 증거 부족은 `unverified`, 조건을 충족하면 `pass`입니다. 프로젝트 규칙을 충족한 최신 최종 후보 한 개만 제시합니다. 최종 기본 브랜치 병합은 사용자가 직접 수행합니다. 도입 프로젝트의 검토판·승격·배포 승인 조건을 적용합니다.

통합 판단 담당이 PR 등록 준비도를 `pass`, `blocked`, `unverified`로 별도 기록합니다. 필수 검토, 통과한 별도 실행, 차단 지적 해소의 이슈 기록과 등록 권한이 모두 확인되면 `pass`입니다. 실행 실패와 미해결 차단 지적은 `blocked`, 필수 증거가 빠지면 `unverified`입니다. PR 등록은 같은 후보 HEAD·대상 브랜치 기준 SHA의 필수 독립 첫 보고서, 별도 실행 검증, 지적 처리를 이슈에 기록하고 해당 PR 등록 준비도가 `pass`인 다음에 진행합니다. 초안 PR에도 같은 조건을 적용합니다. 차단 또는 미확인 상태에서는 이슈에 원인과 필요한 근거를 남기고 PR 등록을 보류합니다. 후보 HEAD 또는 기준 SHA가 바뀌면 새 조합의 근거를 확보한 뒤 등록 또는 검토 요청을 갱신합니다.
