# Third-party notices

emmex is released under the MIT License (see [LICENSE](LICENSE)). It includes, or is adapted
from, the third-party material below, each under its own license.

## Included in this repository

### OpenAI Codex: Seatbelt base policy

- **Where:** `Sources/EmmexCore/Sandbox.swift`. The process, sysctl, Mach, IOKit and device
  allowances in the generated Seatbelt profile, and the guard against renaming a protected
  folder's ancestors, are adapted from Codex's macOS Seatbelt base policy.
- **Source:** https://github.com/openai/codex
- **Copyright:** OpenAI Codex, Copyright 2025 OpenAI.
- **License:** Apache License 2.0, full text in [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).
- **Changes:** the allowances are combined with emmex's own rules (credential read denials,
  workspace-only writes, protected configuration, a per-session temp directory, and network
  egress only to emmex's filtering proxy) and generated per session in Swift.

### mlx-swift-lm (vendored)

- **Where:** `Vendor/mlx-swift-lm`, a copy of https://github.com/ml-explore/mlx-swift-lm.
- **Copyright:** Copyright (c) 2024 ml-explore.
- **License:** MIT, in [Vendor/mlx-swift-lm/LICENSE](Vendor/mlx-swift-lm/LICENSE); its own
  acknowledgments are in `Vendor/mlx-swift-lm/ACKNOWLEDGMENTS.md`.
- **Changes:** KV-cache reuse in the FoundationModels adapter, described in
  [Vendor/mlx-swift-lm/EMMEX-PATCHES.md](Vendor/mlx-swift-lm/EMMEX-PATCHES.md).
- **Includes** xgrammar (`Libraries/MLXCXGrammar/xgrammar`), Apache License 2.0, with its
  `LICENSE` and `NOTICE` kept in place.

## Fetched at build time

Swift Package Manager downloads these; they are not part of this repository. A binary
distribution of emmex (for example `Emmex.app`) contains them compiled and must carry their
license notices.

| Package | License |
| --- | --- |
| ClaudeForFoundationModels (Anthropic) | Apache-2.0 |
| foundation-models-utilities (Apple) | Apache-2.0 |
| mlx-swift (ml-explore) | MIT |
| swift-sdk, Model Context Protocol | MIT |
| swift-huggingface, swift-transformers, swift-jinja (Hugging Face) | Apache-2.0 |
| swift-argument-parser, swift-asn1, swift-atomics, swift-collections, swift-crypto, swift-log, swift-nio, swift-numerics, swift-syntax, swift-system (Apple) | Apache-2.0 |
| EventSource | MIT |
| yyjson | MIT |

Licenses were read from each package's checkout on 2026-09-29; check them again before a
release, since versions change.
