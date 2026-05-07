#!/usr/bin/env bash
#
# Tears down the COTS override demo so you can redeploy with a different method.
# Cleans up all deployment methods. Safe to run multiple times.
#
# Usage: ./scripts/cleanup.sh

set -euo pipefail

echo "==> Deleting ArgoCD Applications..."

# Kyverno method
oc delete application cots-platform-root -n openshift-gitops --ignore-not-found
oc delete application cots-ocp-overrides -n openshift-gitops --ignore-not-found

# Kustomize direct
oc delete application cots-platform-kustomize -n openshift-gitops --ignore-not-found

# Kustomize redirect
oc delete application cots-platform-kustomize-redirect -n openshift-gitops --ignore-not-found

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
echo "  Kyverno — vendor app-of-apps topology preserved, webhook fixes at admission:"
echo "    oc apply -f kyverno/mutate-cots-security.yaml"
echo "    oc apply -f gitops/root/appofapps.yaml"
echo ""
echo "  Kustomize direct — single app, bypasses vendor topology:"
echo "    oc apply -f gitops/kustomize-jsonpatch/argocd-application.yaml"
echo ""
echo "  Kustomize redirect — vendor topology preserved, child apps redirected to overlays:"
echo "    oc apply -f gitops/kustomize-redirect/argocd-application.yaml"
