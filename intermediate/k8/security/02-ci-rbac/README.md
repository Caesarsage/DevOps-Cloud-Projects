
## Demo 2 — Build a Least-Privilege RBAC Policy for a CI Pipeline

You'll create a service account for a CI pipeline that can list pods and read configmaps in the `staging` namespace — and nothing else.

### Step 1: Create the namespace and service account

```bash
kubectl create namespace staging
```

```yaml
# ci-serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-pipeline
  namespace: staging
automountServiceAccountToken: false
```

```bash
kubectl apply -f ci-serviceaccount.yaml
```

### Step 2: Create the Role

```yaml
# ci-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-reader
  namespace: staging
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
```

```bash
kubectl apply -f ci-role.yaml
```

### Step 3: Bind the Role to the service account

```yaml
# ci-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-reader-binding
  namespace: staging
subjects:
  - kind: ServiceAccount
    name: ci-pipeline
    namespace: staging
roleRef:
  kind: Role
  name: ci-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f ci-rolebinding.yaml
```

### Step 4: Test allowed operations

```bash
SA="system:serviceaccount:staging:ci-pipeline"

kubectl auth can-i list pods       --namespace staging     --as $SA   # yes
kubectl auth can-i get  pods       --namespace staging     --as $SA   # yes
kubectl auth can-i list configmaps --namespace staging     --as $SA   # yes
```

### Step 5: Test denied operations

```bash
kubectl auth can-i delete pods       --namespace staging     --as $SA   # no
kubectl auth can-i get  secrets      --namespace staging     --as $SA   # no
kubectl auth can-i list pods         --namespace production  --as $SA   # no
kubectl auth can-i create deployments --namespace staging    --as $SA   # no
```

All four should return `no`. Notice the third test: even if there were a matching Role in the `staging` namespace, the service account cannot access `production`. A `RoleBinding` cannot cross namespace boundaries, this is by design.
