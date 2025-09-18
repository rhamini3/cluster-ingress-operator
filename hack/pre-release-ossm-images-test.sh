#!/bin/bash
KUBERNETES=$(oc config current-context)

echo "Login to konflux cluster to access the index image"
oc login --token=$TOKEN --server=https://api.stone-prod-p02.hjvn.p1.openshiftapps.com:6443

echo "Get the index image"
#INDEX_IMAGE=$(oc get releases -l appstudio.openshift.io/application=ossm-fbc-v4-20 --sort-by=.metadata.creationTimestamp -o name | tail -1 | xargs oc get -ojson | jq -r '.status.artifacts.index_image.index_image')
INDEX_IMAGE=$(oc get releases -l appstudio.openshift.io/application=ossm-fbc-next --sort-by=.metadata.creationTimestamp -o name -n service-mesh-tenant | tail -1 | xargs oc -n service-mesh-tenant get -ojson | jq -r '.status.artifacts.index_image.index_image')
IFS='/' read -ra iib <<< "$INDEX_IMAGE"
INDEX_IMAGE=${iib[@]: -1}

echo "Switch back to kube cluster"
oc config use-context $KUBERNETES

echo "Apply stage files and custom-catalog-source"
oc apply -f -<<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
    name: stage-registry
spec:
    imageTagMirrors:
        - mirrors:
            - registry.stage.redhat.io/openshift-service-mesh
          source: registry.redhat.io/openshift-service-mesh
        - mirrors:
            - registry.stage.redhat.io/openshift-service-mesh-tech-preview
          source: registry.redhat.io/openshift-service-mesh-tech-preview
        - mirrors:
            - registry.stage.redhat.io/openshift-service-mesh-dev-preview-beta
          source: registry.redhat.io/openshift-service-mesh-dev-preview-beta
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
    name: stage-registry
spec:
    imageDigestMirrors:
        - mirrors:
            - registry.stage.redhat.io/openshift-service-mesh
          source: registry.redhat.io/openshift-service-mesh
        - mirrors:
            - registry.stage.redhat.io/openshift-service-mesh-tech-preview
          source: registry.redhat.io/openshift-service-mesh-tech-preview
        - mirrors:
            - registry.stage.redhat.io/openshift-service-mesh-dev-preview-beta
          source: registry.redhat.io/openshift-service-mesh-dev-preview-beta
EOF

oc apply -f -<<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: custom-istio-catalog
  namespace: openshift-marketplace
spec:
  displayName: RH Custom Istio catalog
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
    nodeSelector:
      kubernetes.io/os: linux
      node-role.kubernetes.io/master: ""
    priorityClassName: system-cluster-critical
    securityContextConfig: restricted
    tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
    - effect: NoExecute
      key: node.kubernetes.io/unreachable
      operator: Exists
      tolerationSeconds: 120
    - effect: NoExecute
      key: node.kubernetes.io/not-ready
      operator: Exists
      tolerationSeconds: 120
  image: brew.registry.redhat.io/rh-osbs/$INDEX_IMAGE
  priority: -100
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 30m
EOF

MAX_TRIES=50
TRIES=0

while (( TRIES < MAX_TRIES )); do
    CATALOG_STATE=$(oc get catalogsource -n openshift-marketplace custom-istio-catalog -ojson | jq -r '.status.connectionState.lastObservedState')
    if [[ "$CATALOG_STATE" = "READY" ]]; then
        echo "Condition met!"
        break
    fi
    echo "Try $((TRIES+1)) failed, retrying…"
    ((TRIES++))
    sleep 2
done

if (( TRIES >= MAX_TRIES )); then
    echo "Exceeded max tries"
    exit 1
fi

CUSTOM_CATALOG_SOURCE=custom-istio-catalog
TRIES=0
while (( TRIES < MAX_TRIES )); do
    OSSM_VERSION=$(oc get packagemanifests -n openshift-marketplace -o jsonpath="{range .items[?(@.metadata.labels.catalog=='custom-istio-catalog')]} {.status.channels[*].currentCSV}{\"\n\"}{end}" | grep servicemeshoperator3 | awk '{print $NF}')
    if [[ "$OSSM_VERSION" != "" ]]; then
        echo "OSSM version found!"
        break
    fi
    echo "Try $((TRIES+1)) failed, retrying…"
    ((TRIES++))
    sleep 2
done
if (( TRIES >= MAX_TRIES )); then
    echo "Exceeded max tries"
    exit 1
fi
echo $OSSM_VERSION
OSSM_VERSION=$OSSM_VERSION CUSTOM_CATALOG_SOURCE=$CUSTOM_CATALOG_SOURCE TEST=TestGatewayAPI make test-e2e
echo "Tests completed"