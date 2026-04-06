# GAMA plugin — P2 Composite Repository

This repo manages the **composite p2 update site** for GAMA plugin plugins.

Users point Eclipse to a single URL and transparently install any plugin from the org:

```
https://updates.gama-platform.org/plugin/YYYY.MM/
```

The composite itself contains no plugin code — it is just two XML files (`compositeContent.xml` and `compositeArtifacts.xml`) listing all child p2 repositories, one per plugin repo.

---

## How it works

Each plugin repo in this GitHub org builds and deploys its own self-contained p2 site to a subdirectory on the server:

```
/var/www/gama_updates/plugin/YYYY.MM/
├── compositeContent.xml        ← managed by this repo
├── compositeArtifacts.xml      ← managed by this repo
├── gama.plugin.flooding/ ← deployed by the flooding repo's CI
├── gama.plugin.markdown/ ← deployed by the markdown repo's CI
└── ...
```

When any plugin repo successfully deploys, it fires a `repository_dispatch` event here. This repo's CI then regenerates the composite XMLs from the current list of plugin repos and redeploys them to the server root.

---

## Repo discovery

The composite includes **all non-archived repos in the org** by default, with two opt-out topics:

| Topic | Effect |
|---|---|
| `template` | Excluded — use this on infrastructure/template repos |
| `no-p2` | Excluded — use this to temporarily disable a repo from the composite |

> This repo and `plugin-template` should both carry the `template` topic.

No inclusion tag is needed — a new plugin repo is picked up automatically on its first successful deploy.

---

## Branch and version convention

The GAMA version is derived from the **branch name** at CI time:

```
branch: GAMA_2025-06  →  gama.p2.version = 2025.06
```

The server path is versioned accordingly. When GAMA releases a new version, create a matching branch in this repo and all plugin repos.

The exact server symlink (e.g. `2025.06` → `2025.6.4`) is managed by hand on the VPS.

---

## Org secrets required

All plugin repos and this repo share these org-level secrets:

| Secret | Purpose |
|---|---|
| `GAMA_SERVER_USERNAME` | VPS SSH username |
| `GAMA_SERVER_PASSWORD` | VPS SSH password |
| `GAMA_SERVER_SSH_PRIVATE_KEY` | SSH private key for deployment |
| `GAMA_SERVER_SSH_KNOWN_HOSTS` | Known hosts entry for the VPS |
| `GAMA_KEYSTORE_BASE64` | JAR signing keystore (base64-encoded) |
| `GAMA_KEYSTORE_STOREPASS` | Keystore password |
| `ORG_DISPATCH_TOKEN` | Fine-grained PAT — `contents: write` on this repo, `metadata: read` on org repos |

---

## Triggering a composite update manually

Go to **Actions → Update P2 Composite → Run workflow**.

Useful when a repo was archived, unarchived, or had its topics changed outside of a normal deploy cycle.
