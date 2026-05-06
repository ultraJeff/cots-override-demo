# COTS Override Demo

A working demo of deploying an insecure COTS application on OpenShift and fixing
it via Server-Side Apply overrides — without modifying the vendor's Helm charts.

## The problem

A vendor ships a Helm chart that deploys an ArgoCD Application for each component
(frontend, API, worker). Each child chart creates Deployments that run as root,
allow privilege escalation, and have no seccomp profile. OpenShift's SCC admission
rejects the pods.

You can't modify the vendor charts. You need to patch the rendered resources
after they hit the cluster.

## The deadlock

The naive approach — sync wave 0 installs the vendor chart, sync wave 1 applies
fixes — doesn't work. ArgoCD waits for wave 0 to be healthy before starting
wave 1, but wave 0 can never be healthy because the pods fail SCC. The fix is
in wave 1, which never runs. Deadlock.

## The solution

Deploy both apps simultaneously (no sync waves). The overrides app uses SSA with
retry to keep attempting until the target resources exist, then merges the fixes.

```
Root App (app-of-apps, no sync waves)
  ├── base-install ──────────────────────────────┐
  │   └── vendor parent Helm chart               │  simultaneous
  │       ├── creates Application: cots-frontend  │
  │       ├── creates Application: cots-api       │
  │       └── creates Application: cots-worker    │
  │           └── each deploys insecure pods      │
  │              (fail SCC, that's expected)       │
  │                                               │
  └── ocp-overrides (SSA + Force + retry) ────────┘
      ├── patches Application CRs (add ignoreDifferences)
      └── patches Deployments (fix securityContext)
          └── pods restart with correct spec → pass SCC
```

The overrides app targets two resource types:

| Target | Why |
|---|---|
| **Application CRs** (`overrides/applications/`) | Adds `ignoreDifferences` so child apps stop reverting the security fixes on every sync |
| **Deployments** (`overrides/deployments/`) | Fixes `securityContext` to pass OpenShift's restricted-v2 SCC |

## What's insecure in the vendor charts

| Issue | Where | OpenShift response |
|---|---|---|
| `runAsUser: 0` (root) | Pod securityContext | SCC rejects the pod |
| `allowPrivilegeEscalation: true` | Container securityContext | SCC rejects the pod |
| `capabilities.add: [NET_BIND_SERVICE]` | Container securityContext | SCC rejects the pod |
| No `seccompProfile` | Pod securityContext | SCC rejects the pod |
| No resource requests/limits | Container spec | Quota enforcement fails |

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
└── gitops/
    ├── root/
    │   ├── appofapps.yaml         # Root Application (deploys the two below)
    │   ├── base-install.yaml      # Points to vendor parent chart
    │   └── ocp-overrides.yaml     # SSA + Force + retry, recurse: true
    └── overrides/
        ├── applications/          # Partial Application CRs (add ignoreDifferences)
        │   ├── cots-frontend-app.yaml
        │   ├── cots-api-app.yaml
        │   └── cots-worker-app.yaml
        └── deployments/           # Partial Deployments (fix securityContext)
            ├── frontend.yaml
            ├── api.yaml
            └── worker.yaml
```

## Usage

### Prerequisites

- OpenShift 4.16+ cluster with OpenShift GitOps installed
- `oc` CLI logged in as cluster-admin

### Deploy

Apply the root app-of-apps — everything else cascades from here:

```bash
oc apply -f gitops/root/appofapps.yaml
```

### Watch the sequence

```bash
# Watch the Applications get created
oc get applications -n openshift-gitops -w

# Watch pods fail SCC, then recover after overrides land
oc get pods -n cots-platform -w
```

### Expected behavior

1. `cots-base-install` syncs → creates three child Application CRs
2. Child apps sync → Deployments created → pods fail SCC (expected)
3. `cots-ocp-overrides` syncs (retries until resources exist) →
   patches Application CRs and Deployments via SSA
4. Pods restart with fixed securityContext → pass SCC → go Running
5. All Applications eventually show Healthy

### Clean up

```bash
oc delete application cots-platform-root -n openshift-gitops
```

The finalizers on the child Applications handle cascade deletion.
