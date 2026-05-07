# COTS Override Demo

A working demo of deploying an insecure COTS application on OpenShift and fixing
it — without modifying the vendor's Helm charts.

This repo documents two approaches we tested, what worked, and what didn't.

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

---

## Approach 1: SSA overrides via ArgoCD (what we tried first)

A second ArgoCD Application applies partial manifests via Server-Side Apply to
fix the security context after the vendor charts deploy.

### Why it doesn't work well

SSA **merges** fields — it can't **remove** existing ones. When the vendor chart
sets `runAsUser: 0`, SSA can add `runAsNonRoot: true` alongside it, but can't
remove `runAsUser: 0`. You end up with both, and SCC still rejects the pod.

Even after working around that (setting fields to `null`), we hit a cascade of
ArgoCD-specific problems:

| Problem | Root cause |
|---|---|
| Shared resource errors | ArgoCD won't let two Applications manage the same resource without `annotation` tracking |
| Partial manifests fail validation | ArgoCD treats overrides as desired state, so missing required fields (selector, image) cause validation errors |
| Child apps revert fixes | `selfHeal` re-syncs the Helm values, wiping SSA changes within seconds |
| `ignoreDifferences` not respected | Requires `RespectIgnoreDifferences=true` in syncOptions, which the vendor chart doesn't set |
| Sync wave deadlock | Can't use sync waves because the base install never becomes healthy without the fix |

The SSA approach eventually works, but requires: annotation-based tracking, full
required fields in every partial manifest, `ignoreDifferences` on the child apps,
`RespectIgnoreDifferences=true` via SSA on the Application CRs, retry with backoff,
and `null`/`[]` sentinels to remove fields. It's fragile and hard to maintain.

The SSA manifests are preserved in `gitops/` for reference.

---

## Approach 2: Kyverno mutating webhook (what works)

A Kyverno `ClusterPolicy` intercepts Deployments at admission time and uses
JSON Patch (RFC 6902) to **replace** the insecure securityContext before the
resource is persisted. The Deployment lands on the cluster already fixed.

```
Vendor Helm Chart
  └── ArgoCD creates Deployment
        └── Kyverno webhook intercepts at admission
              └── JSON Patch replaces securityContext
                    └── Deployment persisted with correct spec
                          └── Pods pass SCC ✓
                                └── ArgoCD sees Synced + Healthy ✓
```

### Why this works

| SSA problem | Kyverno solution |
|---|---|
| Can't remove fields | JSON Patch `replace` overwrites the entire securityContext |
| ArgoCD shared resource conflicts | No second Application — Kyverno is a webhook, not an ArgoCD app |
| Child apps revert fixes | Nothing to revert — the Deployment was correct from the start |
| Sync wave deadlock | No deadlock — pods pass SCC on first attempt |
| ArgoCD OutOfSync drift | No drift — ArgoCD's desired state matches live state (Kyverno mutated before persist) |

### Why JSON Patch over Strategic Merge

| Operation | Strategic Merge / SSA | JSON Patch (RFC 6902) |
|---|---|---|
| Add a field | ✓ | ✓ |
| Update a field | ✓ | ✓ |
| Remove a field | ✗ (merge only adds) | ✓ (`remove` or `replace` parent) |
| Replace an entire object | ✗ | ✓ (`replace`) |

When fixing insecure COTS charts, you almost always need to **remove** fields
(`runAsUser: 0`, `capabilities.add`). JSON Patch is the only primitive that
supports this cleanly.

## Project structure

```
├── fake-cots-charts/              # Simulates vendor-provided Helm charts
│   ├── cots-platform/             # Parent chart — creates child ArgoCD Applications
│   │   └── templates/
│   │       ├── namespace.yaml
│   │       ├── app-frontend.yaml  # Renders an ArgoCD Application CR
│   │       ├── app-api.yaml
│   │       └── app-worker.yaml
│   ├── cots-frontend/             # Child chart — insecure Deployment + Service
│   ├── cots-api/                  # Child chart — insecure Deployment + Service
│   └── cots-worker/               # Child chart — insecure Deployment
│
├── kyverno/                       # Method 1: Kyverno mutating webhook
│   └── mutate-cots-security.yaml  # ClusterPolicy with JSON Patch rules
│
├── gitops/
│   ├── root/                      # Method 1: App-of-apps (used with Kyverno)
│   │   ├── appofapps.yaml
│   │   └── base-install.yaml
│   └── kustomize-jsonpatch/       # Method 2: Kustomize + JSON Patch
│       ├── argocd-application.yaml
│       ├── kustomization.yaml
│       └── values.yaml
│
├── gitops-ssa-archive/            # SSA approach (preserved for reference, not deployed)
│
└── scripts/
    └── cleanup.sh                 # Tears down either method for redeployment
```

---

## Deployment methods

Both methods fix the same insecure vendor charts. Run `./scripts/cleanup.sh`
between methods to start fresh.

### Method 1: App-of-apps + Kyverno

Use this when the vendor's Helm chart creates child ArgoCD Applications that
independently deploy their own charts. You can't put Kustomize between the
vendor chart and the cluster, so Kyverno intercepts at admission.

**Prerequisites:** Kyverno installed on the cluster.

```bash
# Install Kyverno (one-time)
helm install kyverno kyverno/kyverno -n kyverno --create-namespace
# On OpenShift, grant nonroot-v2 SCC to Kyverno service accounts
for sa in admission-controller background-controller cleanup-controller reports-controller; do
  oc adm policy add-scc-to-user nonroot-v2 -z kyverno-${sa} -n kyverno
done
oc rollout restart deployment -n kyverno

# Deploy
oc apply -f kyverno/mutate-cots-security.yaml
oc apply -f gitops/root/appofapps.yaml
```

**What happens:**
1. Root app creates `cots-base-install` → vendor parent chart renders child Application CRs
2. Child apps sync → ArgoCD creates Deployments
3. Kyverno intercepts each Deployment at admission → JSON Patch replaces securityContext
4. Deployments are persisted already fixed → pods pass SCC → Running
5. Child apps show **Synced + Healthy** immediately

### Method 2: Kustomize + JSON Patch

Use this when you can put Kustomize in front of the Helm charts. A single ArgoCD
Application pulls all three child charts via Kustomize's `helmCharts` field,
applies JSON Patch to the rendered output, and ArgoCD applies the fixed manifests.
No Kyverno, no app-of-apps.

```bash
oc apply -f gitops/kustomize-jsonpatch/argocd-application.yaml
```

**What happens:**
1. ArgoCD sees a Kustomize source → Kustomize renders the three Helm charts
2. JSON Patches replace securityContext in the rendered output
3. ArgoCD applies the already-fixed Deployments → pods pass SCC → Running
4. Single Application shows **Synced + Healthy**

### Clean up (either method)

```bash
./scripts/cleanup.sh
```

---

## When to use which method

| | Method 1: Kyverno | Method 2: Kustomize JSON Patch |
|---|---|---|
| Vendor deploys via | App-of-apps (chart creates ArgoCD Applications) | Direct Helm charts you control |
| Patch runs | At admission (webhook) | Before apply (Kustomize render) |
| Requires Kyverno | Yes | No |
| ArgoCD Applications | Multiple (root + base + 3 children) | One |
| Complexity | More infrastructure | Simpler |
| Best for | Vendor controls the deployment topology | You control the deployment topology |

Both use JSON Patch (RFC 6902). The difference is where in the pipeline it runs.
See also [Approach 4](https://github.com/ultraJeff/cots-gitops-patterns/tree/main/kustomize-with-helm-jsonpatch)
in the `cots-gitops-patterns` repo for a standalone version of Method 2.
