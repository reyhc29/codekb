# Our fork: how it is set up

This repo is a fork of [awslabs/codekb](https://github.com/awslabs/codekb).
Everything outside `deploy/` is upstream code plus a few small fixes.
Everything we own lives in `deploy/`, so upstream merges never touch it.

## Branches and remotes

| Name | What it is |
| --- | --- |
| `upstream` remote | `https://github.com/awslabs/codekb.git`, read only |
| `origin` remote | `git@github.com:reyhc29/codekb.git`, our fork |
| `main` | a plain copy of `upstream/main`. Never edit it. |
| `dev` | `main` plus our fixes plus `deploy/`. This is what we run. |
| `fix/<name>` | one branch per fix, started from `upstream/main`, sent to awslabs as a PR |

The old 1.4.3 copy is kept in [reyhc29/codekb-legacy](https://github.com/reyhc29/codekb-legacy).

## Get community updates

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout dev  && git merge main
deploy/install.sh run --name codekb-test --port 8744 --restart no   # test copy
# check it, then swap the live one:
docker rm -f codekb-test && deploy/install.sh run
```

When awslabs merges one of our fixes, `git merge main` brings in their copy.
Our copy then goes away by itself, or needs a small conflict fix.

## Our fixes on top of upstream

| Branch | What | Upstream PR |
| --- | --- | --- |
| `fix/refresh-v1-shared-stem` | refresh no longer fails with `invariant_violation` on old (V1 id) spaces where two files share a name | to open |

## Run it

```bash
deploy/install.sh run      # build if needed, then (re)start on 127.0.0.1:8742
deploy/install.sh status
deploy/install.sh down
deploy/install.sh mcp      # MCP client snippet
```

Settings live in `deploy/codekb.conf`. The container runs as the host user, so
it can read `~/.aws` and the ssh key in `~/.ssh` (mounted read-only).
