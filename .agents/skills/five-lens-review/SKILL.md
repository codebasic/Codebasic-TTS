---
name: five-lens-review
description: Coordinate an independent five-perspective review of a specific software revision, preview, or release. Use when asked for the full review or to compare the practical value of matched reviewer teams.
---

# Five-lens review · 5관점 리뷰

Invoke in a local Codex app session whose workspace contains this preset:

`$five-lens-review Review product <target-sha> against <base-sha> in <source-checkout>. Use read-only evidence and report preview and release readiness separately.`

## Prepare the review

- Resolve the exact product target and base to commit IDs and record the checkout and authorized evidence. If the preset and product are on different revisions, use the product commits for source, diff, and finding line references. Keep the preset checkout as the session workspace for role discovery.
- Verify the local Codex app harness can address the five named project roles. Confirm the requested model is available and check the parent permission mode, tools, and source access. Child roles inherit those controls. Set a read-only parent permission mode to enforce the file instructions. Use the app's native subagent mechanism. If the host cannot start a named role or verify runtime metadata, report that exact limit and distinguish configured values from observed ones.
- Send the same neutral brief to each reviewer, including goal, target and base SHAs, original source and diff access, evidence paths and provenance, allowed actions, and reporting format. Check that each reviewer can independently read the source and diff. Keep private material within the authorized harness.

## Run the independent passes

Start one named subagent for each lens. Use fresh contexts where possible and keep sibling output and previous conclusions out of each brief. Collect the five first reports privately and record their completion before discussing them or sending cross-check requests.

| Lens | Project role |
| --- | --- |
| Software engineering · 소프트웨어 공학 | `five_lens_software` |
| UI and UX · UI/UX | `five_lens_ui_ux` |
| End user · 최종 사용자 | `five_lens_end_user` |
| Defensive security · 방어적 보안 | `five_lens_security` |
| Deployment · 배포 | `five_lens_deployment` |

## Report claims with evidence

Each reviewer records their role, observed harness and model metadata when available, inspected artifacts, and verification limits. Give each finding a severity, affected scenario, and consequence. For every material claim in a first report or the synthesis, cite the exact reviewed commit SHA and source `file:line`. Add the verification command and observed result, or link the specific screen capture, recording, log, or other artifact supporting the claim. Attribute existing evidence to its original run. If no source location applies, give the precise artifact location and describe any gap in its link to the commit.

Label material claims by how they were established:

- **Direct execution · 직접 실행** — Record the command and result, or the observed UI steps and supporting artifact. Identify whether the environment was a synthetic fixture, actual UI, or a real provider.
- **Static inference · 정적 추론** — Cite the exact source path and lines and state what they imply. Identify any supporting evidence from prior runs.
- **Unverified · 미확인** — State the exact gap and the evidence needed to resolve it. An unresolved hypothesis belongs here.

Say when no finding was established or a lens could not run. Follow the authorized scope for checks and keep defensive security within static review and existing evidence.

## Synthesize the evidence

- After first reports are fixed, reconcile issues by underlying mechanism. Preserve contradictory evidence and explain the disposition of duplicates, false positives, and unverified hypotheses. Put verified and material findings first and identify the corresponding fix or decision when available.
- Make separate preview and release decisions using `pass`, `blocked`, or `unverified`. Name the evidence for each decision and the unresolved condition that could change it. Preview concerns the proposed isolated experience. Release also considers the applicable distribution, operational readiness, and real-environment evidence. These are review decisions with separate authorization for any action.
- If comparing Sol with another provider, give both teams the same source revisions, evidence, scope, and five lenses. Save both independent first reports before either team sees the other's findings. Credit only verified unique defects and documented outcomes, such as a fix actually made or a preview or release decision that changed. Track review comment volume, duplicates, false positives, and unverified hypotheses as diagnostics, with no performance credit. Record extra elapsed time and execution cost when measured, and mark missing values as unknown. Draw the conclusion from impact and marginal evidence.
