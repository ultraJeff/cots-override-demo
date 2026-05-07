#!/usr/bin/env bash
#
# Tears down the COTS override demo so you can redeploy with a different pattern.
# Safe to run multiple times.
#
# Usage: ./scripts/cleanup.sh

set -euo pipefail

echo "==> Deleting ArgoCD Applications (cascade deletes child resources)..."
oc delete application cots-platform-root -n openshift-gitops --ignore-not-found
oc delete application cots-ocp-overrides -n openshift-gitops --ignore-not-found

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
echo "To redeploy:"
echo "  1. Apply the Kyverno policy:  oc apply -f kyverno/mutate-cots-security.yaml"
echo "  2. Deploy the app-of-apps:    oc apply -f gitops/root/appofapps.yaml"
