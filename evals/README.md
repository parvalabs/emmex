# Classifier evals

Offline accuracy and latency checks for the classifiers mlex runs on every turn: the router
(local, cheap or frontier) and the smart-mode safety judge (safe, review or dangerous).

- `data/routing.jsonl`: 94 requests, 12 of them short replies that depend on the previous turn.
- `data/commands.jsonl`: 60 shell commands, from builds and tests to exfiltration.
- `data/secrets.jsonl` and `data/secrets-holdout.jsonl`: 56 and 24 messages for the secret
  scanner, hand-labelled. `{{name}}` placeholders expand to synthetic tokens at runtime
  (`EvalHarness.fixture`), so the repo holds nothing that looks like a live credential.
  Run with `mlex eval secrets` (`--dir` for the held-out copy).
- Routing and command labels come from Opus 5.5, given the same tier and safety definitions the classifiers get
  (`TierGuide` in `Router.swift`, `SafetyClassifier` in `Permissions.swift`).

```bash
.build/debug/mlex eval label          # label items that have no label yet (Claude, Keychain key)
.build/debug/mlex eval run            # on-device 3B router and safety judge
evals/.venv/bin/python evals/laya_eval.py   # Laya (see below)
python3 evals/compare.py              # score everything in results/
```

Routing is scored on accuracy and on under-routing, which sends work to a tier too weak for it.
Safety is scored on unsafe allows, a non-safe command judged safe, which would run unasked.
The "rules first" table applies the policy engine's deterministic rules before the classifier,
as smart mode does, so only gray-zone commands reach the model.

## Laya

[aac6fef/laya-mlx](https://huggingface.co/aac6fef/laya-mlx) is a 0.4B ModernBERT decision
encoder (Apache-2.0), an independent MLX port of Convai Innovations' Laya. The eval runs it
through its Python package in a venv:

```bash
/opt/homebrew/bin/python3.12 -m venv evals/.venv
evals/.venv/bin/pip install laya-mlx==0.2.0
```

Weights go to `~/.cache/mlex/classifiers/laya-mlx`, outside the MLX chat model library.
