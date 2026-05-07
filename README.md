# COTS Override Demo

A working demo of deploying an insecure COTS application on OpenShift and fixing
it — without modifying the vendor's Helm charts.

This repo documents three working approaches, one failed approach (SSA), and the
reasoning behind each.

## The problem

A vendor ships a Helm chart that deploys an ArgoCD Application for each component
(frontend, API, worker). Each child chart creates Deployments that run as root,
allow privilege escalation, and have no seccomp profile. OpenShift's SCC admission
rejects the pods.

You can't modify the vendor charts. You need to fix the rendered resources.

## What's insecure in the vendor charts

| Issue | Where | OpenShift response |
|---|---|---|
| `runAsUser: 0` (root) | Pod securityContext | SCC rejects the pod |
| `allowPrivilegeEscalation: true` | Container securityContext | SCC rejects the pod |
| `capabilities.add: [NET_BIND_SERVICE]` | Container securityContext | SCC rejects the pod |
| No `seccompProfile` | Pod securityContext | SCC rejects the pod |
| No resource requests/limits | Container spec | Quota enforcement fails |

## Why JSON Patch (not strategic merge or SSA)

All three working methods use JSON Patch (RFC 6902). This is not a style choice —
it's the only patching primitive that can **remove** fields.

| Operation | Strategic Merge / SSA | JSON Patch (RFC 6902) |
|---|---|---|
| Add a field | Yes | Yes |
| Update a field | Yes | Yes |
| Remove a field | No (merge only adds) | Yes (`remove` or `replace` parent) |
| Replace an entire object | No | Yes (`replace`) |

When a vendor chart sets `runAsUser: 0`, strategic merge can add `runAsNonRoot: true`
alongside it but can't remove `runAsUser: 0`. You end up with both, and SCC still
rejects the pod. JSON Patch's `replace` operation overwrites the entire
`securityContext` object — the insecure fields are gone, not overridden.

---

## Three deployment methods

All three fix the same insecure vendor charts. Run `./scripts/cleanup.sh` between
methods to start fresh.

### Kyverno — mutating webhook

The recommended approach when the vendor controls the deployment topology
(parent chart creates child ArgoCD Applications).

A Kyverno `ClusterPolicy` intercepts Deployments at admission time and uses
JSON Patch to replace the insecure securityContext before the resource is
persisted. The vendor's app-of-apps topology is completely untouched.

```
Vendor Parent Chart
  └── creates child ArgoCD Applications
        └── child apps create Deployments
              └── Kyverno intercepts at admission
                    └── JSON Patch replaces securityContext
                          └── Deployment persisted already fixed → pods pass SCC
```

**Strengths:**
- Vendor topology completely preserved
- Automatically covers new components the vendor adds (policy matches by namespace)
- No knowledge of vendor chart internals required
- No chart duplication

**Tradeoffs:**
- Requires Kyverno on the cluster
- Child apps show OutOfSync (live state differs from Helm-rendered state due to mutation)

```bash
oc apply -f kyverno/mutate-cots-security.yaml
oc apply -f gitops/root/appofapps.yaml
```

### Kustomize direct — single app, bypass vendor topology

The simplest approach when you can pull the child charts yourself and don't need
the vendor's app-of-apps structure.

A single ArgoCD Application uses Kustomize's `helmCharts` field to render all
three child charts, applies JSON Patch to the output, and ArgoCD applies the
fixed manifests. No app-of-apps, no Kyverno.

**Strengths:**
- Simplest setup — one Application, one kustomization.yaml
- All apps show Synced + Healthy (no drift)
- No external tools required

**Tradeoffs:**
- Bypasses the vendor's deployment topology entirely
- You must know which child charts to pull and how they're configured
- Vendor updates require manual tracking

```bash
oc apply -f gitops/kustomize-jsonpatch/argocd-application.yaml
```

### Kustomize redirect — vendor topology preserved, child apps redirected

A pure-Kustomize approach that preserves the vendor's app-of-apps topology.
Kustomize renders the vendor's parent chart, JSON Patches the Application CRs
to redirect each child app to a Kustomize overlay, and each overlay wraps the
child chart with JSON Patch fixes.

```
Vendor Parent Chart (rendered by Kustomize)
  └── Application CRs get JSON Patched:
        - spec.source.path → our overlay
        - spec.source.helm → removed (so ArgoCD detects Kustomize)
        └── child apps now point at our overlays
              └── each overlay renders the child chart + JSON Patch
                    └── Deployments are fixed before apply → pods pass SCC
```

**Strengths:**
- No Kyverno required
- Preserves vendor's app-of-apps structure
- All apps show Synced + Healthy (no drift)

**Tradeoffs:**
- Open-heart surgery — you're reverse-engineering the vendor's topology
- Requires a copy of each vendor chart inside your overlay directories
  (Kustomize's security sandbox won't allow `chartHome` to reference parent directories;
  in production you'd use `helmCharts.repo` pointing at the vendor's Helm registry instead)
- If the vendor adds components, renames charts, or restructures, your redirects break
- Most complex to set up and maintain

```bash
oc apply -f gitops/kustomize-redirect/argocd-application.yaml
```

---

## Which method should I use?

| | Kyverno | Kustomize direct | Kustomize redirect |
|---|---|---|---|
| Vendor topology preserved | Yes | No | Yes |
| Requires Kyverno | Yes | No | No |
| ArgoCD Applications | Multiple (vendor's) | One | Multiple (vendor's, redirected) |
| Vendor adds a component | Auto-covered by policy | Must add manually | Must add manually |
| Chart duplication | None | None | Yes (sandbox constraint) |
| ArgoCD sync status | OutOfSync (mutation drift) | Synced | Synced |
| Maintenance burden | Low | Medium | High |
| Best for | Production | Simple/dev environments | Teams that can't install Kyverno |

**Recommendation:** Use **Kyverno** in production. It's the lowest maintenance, handles
vendor changes gracefully, and doesn't require knowledge of the vendor's chart internals.
Use **Kustomize direct** for simple cases where you control the charts. Use **Kustomize
redirect** only if you need to preserve the vendor topology and can't install Kyverno.

---

## What we tried and abandoned: SSA overrides

Before finding the JSON Patch approaches, we tried using a second ArgoCD Application
with Server-Side Apply to patch Deployments after the vendor charts deployed.

SSA merges fields but can't remove them. Even after workarounds (`null` sentinels,
`capabilities.add: []`), we hit a cascade of ArgoCD-specific problems:

| Problem | Root cause |
|---|---|
| Shared resource errors | ArgoCD won't let two Applications manage the same resource without `annotation` tracking |
| Partial manifests fail validation | ArgoCD treats overrides as desired state — missing required fields (selector, image) cause errors |
| Child apps revert fixes | `selfHeal` re-syncs Helm values, wiping SSA changes within seconds |
| `ignoreDifferences` not respected | Requires `RespectIgnoreDifferences=true` in syncOptions, which the vendor chart doesn't set |
| Sync wave deadlock | Can't gate on health because the base install can never be healthy without the fix |

The SSA manifests are preserved in `gitops-ssa-archive/` for reference.

---

## Project structure

```
├── fake-cots-charts/                  # Simulates vendor-provided Helm charts
│   ├── cots-platform/                 # Parent chart — creates child ArgoCD Applications
│   ├── cots-frontend/                 # Child chart — insecure Deployment + Service
│   ├── cots-api/                      # Child chart — insecure Deployment + Service
│   └── cots-worker/                   # Child chart — insecure Deployment
│
├── kyverno/                           # Kyverno method
│   └── mutate-cots-security.yaml      # ClusterPolicy with JSON Patch rules
│
├── gitops/
│   ├── root/                          # Kyverno method: app-of-apps
│   │   ├── appofapps.yaml
│   │   └── base-install.yaml
│   ├── kustomize-jsonpatch/           # Kustomize direct method
│   │   ├── argocd-application.yaml
│   │   ├── kustomization.yaml
│   │   └── values.yaml
│   └── kustomize-redirect/            # Kustomize redirect method
│       └── argocd-application.yaml
│
├── kustomize-redirect/                # Kustomize redirect: parent + child overlays
│   ├── kustomization.yaml             # Renders parent chart, patches Application CRs
│   ├── charts/                        # Copy of vendor parent chart
│   ├── child-frontend/                # Overlay: renders + patches frontend chart
│   ├── child-api/                     # Overlay: renders + patches API chart
│   └── child-worker/                  # Overlay: renders + patches worker chart
│
├── gitops-ssa-archive/                # SSA approach (preserved for reference)
│
└── scripts/
    └── cleanup.sh                     # Tears down any method for redeployment
```

## Related

- [cots-gitops-patterns](https://github.com/ultraJeff/cots-gitops-patterns) — broader
  collection of patterns for deploying COTS apps on OpenShift with ArgoCD, including
  strategic merge, JSON Patch, and app-of-apps approaches
