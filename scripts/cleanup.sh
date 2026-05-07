#!/usr/bin/env bash
#
# Tears down the COTS override demo so you can redeploy with a different method.
# Cleans up both deployment methods. Safe to run multiple times.
#
# Usage: ./scripts/cleanup.sh

set -euo pipefail

echo "==> Deleting ArgoCD Applications..."

# Method 1: App-of-apps + Kyverno
oc delete application cots-platform-root -n openshift-gitops --ignore-not-found
oc delete application cots-ocp-overrides -n openshift-gitops --ignore-not-found

# Method 2: Kustomize + JSON Patch
oc delete application cots-platform-kustomize -n openshift-gitops --ignore-not-found

# Method 3: Helm with Kustomize JSON Patch
oc delete application cots-platform-helm-kustomize -n openshift-gitops --ignore-not-found

echo ""
echo "==> Waiting for child Applications to be cleaned up..."
sleep 5
for app in cots-base-install cots-frontend cots-api cots-worker; do
  oc delete application "$app" -n openshift-gitops --ignore-not-found
done

echo ""
echo "==> Deleting Kyverno policy..."
oc delete clusterpolicy mutate-cots-platform-security --ignore-not-found

echo ""
echo "==> Deleting cots-platform namespace..."
oc delete namespace cots-platform --ignore-not-found

echo ""
echo "==> Verifying cleanup..."
echo "Applications:"
oc get applications -n openshift-gitops 2>/dev/null | grep cots || echo "  (none)"
echo "Namespace:"
oc get namespace cots-platform 2>/dev/null || echo "  (deleted)"

echo ""
echo "==> Cleanup complete. Ready to redeploy."
echo ""
echo "Deployment methods:"
echo ""
echo "  Method 1 — App-of-apps + Kyverno (vendor chart creates child ArgoCD Applications):"
echo "    oc apply -f kyverno/mutate-cots-security.yaml"
echo "    oc apply -f gitops/root/appofapps.yaml"
echo ""
echo "  Method 2 — Kustomize + JSON Patch (single ArgoCD Application, no Kyverno):"
echo "    oc apply -f gitops/kustomize-jsonpatch/argocd-application.yaml"
echo ""
echo "  Method 3 — Helm with Kustomize JSON Patch (multi-source, vendor topology preserved):"
echo "    oc apply -f gitops/helm-with-kustomize-jsonpatch/argocd-application.yaml"
