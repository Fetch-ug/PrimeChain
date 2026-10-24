# Pre-push checklist

For a machine with no Foundry and no Docker: **nothing needs to run locally.**
CI is the only execution environment, which is why it is configured to prove as
much as possible (build, tests, invariants, coverage, deploy + RPC reads) and to
stay green on things the authoring machine could not verify (formatting).

## 0. Delete two sandbox artefacts (30 seconds)

These were created while probing this environment and are **excluded from the
zip**, but if you are pushing the working directory instead of the zip, remove
them first:

```powershell
Remove-Item _delete_probe.txt
Remove-Item .github\workflows\_probe.yml
```

`.dsh\` is harness internals — it is git-ignored, leave it alone.

## 1. Confirm the sensitive stuff is absent

```powershell
Get-ChildItem -Recurse -Force -File -Include *.env,.env* | Select-Object FullName   # expect: nothing
Select-String -Path (Get-ChildItem -Recurse -File).FullName -Pattern '0x[0-9a-fA-F]{64}' |
  Select-Object Path, LineNumber
```

The only 64-hex literal in the tree should be Anvil's public dev key in
`.github/workflows/contracts.yml`, which is labelled as worthless. The CI
workflow `secrets` re-checks this on every push.

## 2. Push

```powershell
git init
git add .
git commit -m "phase1: Prime token, tests, CI, devnet runbook"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

## 3. Watch for exactly two workflows

| Workflow | Jobs | Expected Phase 1 result |
|---|---|---|
| `contracts` | `build-and-test`, `deploy + RPC smoke (anvil)` | **green** is the goal; formatting step is advisory |
| `secrets` | `no credentials in tree` | green |

You should **not** see a `slither` job — it moved to Phase 6 (see
[DEPENDENCIES.md](DEPENDENCIES.md)).

## 4. If `Format check` reports differences

It is marked `continue-on-error: true`, so the job still passes and only shows a
warning annotation. To fix it anyway, on GitHub: **Actions → format → Run
workflow → Run workflow** (branch `main`). That job runs `forge fmt` and commits
the result. It is the only way to format without a local Foundry install.

## 5. What to send back

Either is enough:

- the `contracts` run URL (success **or** failure), or
- the failing step's log (the last ~60 lines is plenty), or
- if `deploy + RPC smoke` fails, the "Dump anvil log on failure" output plus the
  `Resolve deployed address` step.

I will record the outcome in [PROGRESS.md](PROGRESS.md) and, if green, mark Phase 1
complete and ask for the go-ahead to Phase 2.

## 6. Known-expected, do not panic

| Symptom | Cause | Action |
|---|---|---|
| `Format check` annotation only | never ran `forge fmt` locally | run the `format` workflow, or ignore |
| `could not download solc 0.8.28` | transient network | re-run the job |
| `bootstrap-deps.sh: openzeppelin-contracts is at …, expected …` | the `v5.7.0` tag moved upstream | stop, tell me — do not "fix" the SHA by hand |
| `deploy-smoke` skipped | `build-and-test` failed | fix the first failure; `needs:` is intentional |
