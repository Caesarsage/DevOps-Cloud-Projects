## Demo 3 — Audit RBAC with rakkess and rbac-lookup

Now you'll scan the full cluster to surface any accounts with more permissions than they need.

### Step 1: Install the tools

```bash
kubectl krew install access-matrix
kubectl krew install rbac-lookup
```

### Step 2: Run rakkess across the cluster

```bash
# All service accounts in kube-system
kubectl access-matrix --namespace kube-system

# All ServiceAccounts cluster-wide
kubectl access-matrix --sa
```

### Step 3: Find all cluster-admin bindings

```bash
kubectl rbac-lookup cluster-admin --kind ClusterRole --output wide
```

Expected output on a fresh kind cluster:

```plaintext
SUBJECT                          SCOPE          ROLE
system:masters                   cluster-wide   ClusterRole/cluster-admin
kubernetes-admin                 cluster-wide   ClusterRole/cluster-admin
system:kube-controller-manager   cluster-wide   ClusterRole/cluster-admin
```

The first two entries are expected — `system:masters` is the built-in admin group, and `kubernetes-admin` is your kubeconfig user. The concern is if you see application service accounts bound to `cluster-admin`. If you do, that is your first remediation task.

### Step 4: Verify the ci-pipeline service account

```bash
kubectl rbac-lookup ci-pipeline --kind ServiceAccount --output wide
```

Expected output:

```plaintext
SUBJECT      SCOPE     ROLE
ci-pipeline  staging   Role/ci-reader
```

This confirms the service account is bound only to the namespace-scoped Role you created. Nothing else, nowhere else.
