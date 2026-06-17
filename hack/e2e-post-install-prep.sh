#!/bin/sh
# Runs Blockstor pool + StorageClass + MetalLB pool configuration as soon
# as their respective prerequisites are reachable. Designed to run in the
# background during the platform HR reconcile wait, so its wall-clock cost
# overlaps with the wait instead of compounding it.
#
# PoC: LINSTOR was replaced by Blockstor. piraeus-operator runs in
# EXTERNAL mode (no in-cluster linstor-controller to exec into); the
# storage backend is the blockstor controller/apiserver/satellite stack.
# We create the backing `data` zpool on each worker's /dev/vdc directly
# inside the blockstor-satellite pod, then declare a per-node StoragePool
# CRD named `data` backed by that zpool. The StorageClasses are unchanged
# — blockstor serves the same csi wire-shape, so provisioner
# linstor.csi.linbit.com + storagePool: data keeps working.
set -eu

NS=cozy-linstor
ZPOOL=data        # backing ZFS zpool name on the node
POOL=data         # blockstor StoragePool name (matches the SC storagePool param)
DISK=/dev/vdc     # spare data disk on every worker

echo "[post-install-prep] waiting for linstor HelmRelease object to exist"
timeout 60 sh -ec 'until kubectl get hr/linstor -n '"$NS"' >/dev/null 2>&1; do sleep 2; done'

echo "[post-install-prep] waiting for linstor HelmRelease to be Ready"
kubectl wait helmrelease/linstor -n "$NS" --for=condition=Ready --timeout=15m

echo "[post-install-prep] waiting for blockstor-apiserver deployment to exist"
timeout 300 sh -ec 'until kubectl get deploy/blockstor-apiserver -n '"$NS"' >/dev/null 2>&1; do sleep 2; done'

echo "[post-install-prep] waiting for blockstor-apiserver to be Available"
kubectl wait deployment/blockstor-apiserver -n "$NS" --timeout=5m --for=condition=available

echo "[post-install-prep] waiting for blockstor-controller to be Available"
kubectl wait deployment/blockstor-controller -n "$NS" --timeout=5m --for=condition=available

echo "[post-install-prep] waiting for LinstorCluster Available (external mode)"
timeout 300 sh -ec 'until kubectl get linstorcluster linstorcluster -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null | grep -q True; do sleep 5; done'

echo "[post-install-prep] waiting for 3 blockstor-satellite pods Ready"
timeout 300 sh -ec 'until [ $(kubectl -n '"$NS"' get pods -l app=blockstor-satellite --no-headers 2>/dev/null | awk "{print \$2}" | grep -c "^1/1$") -eq 3 ]; do sleep 5; done'

echo "[post-install-prep] creating '$ZPOOL' zpool on $DISK + StoragePool '$POOL' (parallel across satellites)"
pids=""
for pod in $(kubectl -n "$NS" get pods -l app=blockstor-satellite -o jsonpath='{.items[*].metadata.name}'); do
  (
    node=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.nodeName}')
    # Create the backing zpool inside the satellite pod (it has the
    # privileged /dev + /run/udev + /lib/modules mounts libzfs needs).
    # Idempotent: skip if the pool already exists. Mirrors blockstor
    # stand/install-pools.sh create_zfs — partition first, then hand
    # zpool the partition path (whole-disk zpool create's GPT-rescan
    # fails inside the container's devtmpfs view).
    kubectl -n "$NS" exec "$pod" -- sh -ec '
      if zpool list '"$ZPOOL"' >/dev/null 2>&1; then
        echo "zpool '"$ZPOOL"' already exists on '"$node"'"
        exit 0
      fi
      wipefs -af '"$DISK"'* 2>/dev/null || true
      sgdisk --zap-all '"$DISK"' 2>/dev/null || true
      sgdisk --new=1:0:0 -t 1:bf01 '"$DISK"'
      partprobe '"$DISK"' 2>/dev/null || true
      sleep 1
      zpool create -f -o cachefile=none '"$ZPOOL"' '"$DISK"'1
      echo "zpool '"$ZPOOL"' created on '"$node"'"
    '
    # Declare the StoragePool CRD. The CRD CEL rule pins
    # metadata.name == <poolName>.<nodeName> (lowercased), so the name
    # MUST be data.<node>. StorDriver/ZPoolThin points at the zpool.
    kubectl apply -f - <<EOF
apiVersion: blockstor.cozystack.io/v1alpha1
kind: StoragePool
metadata:
  name: ${POOL}.${node}
spec:
  nodeName: ${node}
  poolName: ${POOL}
  providerKind: ZFS_THIN
  props:
    StorDriver/ZPoolThin: ${ZPOOL}
EOF
  ) &
  pids="$pids $!"
done
for pid in $pids; do
  wait "$pid"
done

echo "[post-install-prep] StoragePools:"
kubectl get storagepools -o wide 2>/dev/null || true

echo "[post-install-prep] applying StorageClasses"
kubectl apply -f - <<'EOF'
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: "data"
  linstor.csi.linbit.com/layerList: "storage"
  linstor.csi.linbit.com/allowRemoteVolumeAccess: "false"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: replicated
provisioner: linstor.csi.linbit.com
parameters:
  linstor.csi.linbit.com/storagePool: "data"
  linstor.csi.linbit.com/autoPlace: "3"
  linstor.csi.linbit.com/layerList: "drbd storage"
  linstor.csi.linbit.com/allowRemoteVolumeAccess: "true"
  property.linstor.csi.linbit.com/DrbdOptions/auto-quorum: suspend-io
  property.linstor.csi.linbit.com/DrbdOptions/Resource/on-no-data-accessible: suspend-io
  property.linstor.csi.linbit.com/DrbdOptions/Resource/on-suspended-primary-outdated: force-secondary
  property.linstor.csi.linbit.com/DrbdOptions/Net/rr-conflict: retry-connect
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

echo "[post-install-prep] waiting for MetalLB CRDs"
timeout 300 sh -ec 'until kubectl get crd ipaddresspools.metallb.io l2advertisements.metallb.io >/dev/null 2>&1; do sleep 2; done'

echo "[post-install-prep] applying MetalLB IPAddressPool"
kubectl apply -f - <<'EOF'
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: cozystack
  namespace: cozy-metallb
spec:
  ipAddressPools: [cozystack]
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: cozystack
  namespace: cozy-metallb
spec:
  addresses: [192.168.123.200-192.168.123.250]
  autoAssign: true
  avoidBuggyIPs: false
EOF

echo "[post-install-prep] done"
