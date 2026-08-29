# Skipper

An AI operations layer you talk to like a manager. It runs your work on a
schedule in the background and shows you what it did in the Dynamic Island, so
you never open an app to know where things stand.

## What it does

You give Skipper an outcome. The **Maestro** reads it and either hands it to one
specialist or breaks it into steps and delegates. Sub-agents execute in four
parallel lanes — `build`, `comms`, `device`, `research` — and every result is
checked by a verifier that re-reads the actual artifact from production rather
than trusting the worker's own report.

Anything that needs you shows up in the Island. Everything else just gets done.

## Architecture

```
iPhone ──► skipper-api ──► maestro schema (Postgres)
                              │
              cron ──► maestro-tick ──► planner ──► 4 parallel lanes
                              │                        │
                              │                    verifier
                              ▼                        │
                        maestro-push ◄─────────────────┘
                              │
                              ▼
                    Dynamic Island / Lock Screen
```

**The app ships with no credential.** On first launch it registers with nothing
but a locally generated install id and receives a per-install token. That is why
this repo is public — there is no key in it to leak, and compromising one
install exposes exactly one install.

## Verification contract

Four verdicts, and the distinction between the last two is the point:

| verdict | meaning |
|---|---|
| `pass` | the artifact demonstrably satisfies the success test |
| `fail` | wrong, and a retry could plausibly fix it |
| `unclear` | the fetch failed or the result is still in flight |
| `bad_test` | the work is right but the test itself is unsatisfiable |

`bad_test` escalates to you instead of burning retries against a test that can
never pass. Research produces a stored **finding**, so an answer is a real
artifact the verifier can re-read rather than a claim it has to take on faith.

## Lanes

One lock per domain. Work in **different** domains runs simultaneously; work in
the **same** domain is serialised on purpose, so two build tasks never race on
the same repository.

## Building

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open Skipper.xcodeproj
```

Set your team in `project.yml` (`DEVELOPMENT_TEAM`) before building to a device.
Live Activities do not run in the Simulator's Dynamic Island — a physical device
is required to see the Island surfaces.

## Layout

```
Shared/SkipperAttributes.swift   Live Activity contract — must match island_state()
Skipper/SkipperAPI.swift          the only network layer; no secret ships here
Skipper/Office.swift             model for the full landscape payload
Skipper/OfficeView.swift         the office screen
Skipper/SkipperApp.swift          push tokens, Activity control, command poller
SkipperWidget/                   every Dynamic Island surface
```

## Status

Server is live and verified end to end: planning, delegation, parallel lanes,
verification, budget ceiling, and APNs signing. The iOS client is written but
**has not yet been built or run on a device.**
