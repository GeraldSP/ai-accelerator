# Tenant wizard

Merge-friendly tooling to add **tenants GitOps wiring** and **pointer Applications** without putting tenant workloads in upstream `main`.

## Why a separate branch

- Branch **`tenant-wizardry`** (from `main`) contains only this wizard (script, templates, docs).
- Working branches (e.g. `summit-connect-chile`) **merge** `tenant-wizardry`, then **run** the script.
- Upstream `main` stays free of tenant inventory → cleaner merges/rebases.
- The script **refuses to run** while you are checked out on `tenant-wizardry`.

## Merge workflow

```bash
# 1) Update wizard branch when the script changes (on tenant-wizardry)
git checkout tenant-wizardry
# ... edit scripts/tenant-wizard* ...
git commit && git push

# 2) On a working cluster branch
git checkout summit-connect-chile
git merge tenant-wizardry

# 3) Run the wizard (writes to the working branch only; no commit/push)
./scripts/tenant-wizard.sh
# or batch:
./scripts/tenant-wizard.sh --config scripts/my-tenants.yaml

# 4) Review and commit on the working branch
git status
git add ...
git commit -m "Register tenants via tenant-wizard"
```

When upstream moves:

```bash
git checkout summit-connect-chile
git merge origin/main          # or rebase; tenants stay local to this branch
git merge tenant-wizardry      # only if the wizard itself changed
```

## What the script generates

1. AppProject `tenants`
2. ApplicationSet `tenants` (git generator on **core** repo under `tenants/*/*/overlays/<overlay>`)
3. Overlay patch + apps overlay wiring
4. Cluster overlay replacements for the tenants ApplicationSet **generator** (core repo URL/revision)
5. Pointer Applications:

```text
tenants/<tenant-id>/remote/base/application.yaml
tenants/<tenant-id>/remote/overlays/<overlay>/kustomization.yaml
```

Pointers point at **external** tenant repos. Workloads live there, not in core.

## Modes

- `bootstrap` — wiring only
- `register` — pointer Apps only
- `both` — default

## Duplicate tenant ids

If `tenants/<id>/` already exists for the overlay, the script **warns**.

- Interactive: choose `skip` or `overwrite`
- Batch YAML: skip unless `overwrite: true`

## Confirmation

Before writing files you must type exactly:

```text
do it!
```

Max 3 attempts, then abort.

## Example config

See [`../tenant-wizard.example.yaml`](../tenant-wizard.example.yaml).

## Requirements

- `git`, `python3`, `sed`
- `yq` when using `--config`
