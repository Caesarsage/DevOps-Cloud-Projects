## Demo 1 — Create and Use an x509 Client Certificate

You'll generate a user certificate signed by the cluster CA, bind it to an RBAC role, and use it to authenticate to the cluster as a different user.

### Step 1: Copy the CA cert and key from the kind control plane

```bash
docker cp k8s-security-control-plane:/etc/kubernetes/pki/ca.crt ./ca.crt
docker cp k8s-security-control-plane:/etc/kubernetes/pki/ca.key ./ca.key
```

This will create two files in your current directory called `ca.crt` ans `ca.key`


### Step 2: Generate a private key and CSR for a new user

You're creating a certificate for a user named `jane` in the `engineering` group:

```bash
# Generate the private key
openssl genrsa -out jane.key 2048

# Generate a Certificate Signing Request
# CN = username, O = group
openssl req -new \
  -key jane.key \
  -out jane.csr \
  -subj "/CN=jane/O=engineering"
```

### Step 3: Sign the CSR with the cluster CA

```bash
openssl x509 -req \
  -in jane.csr \
  -CA ca.crt \
  -CAkey ca.key \
  -CAcreateserial \
  -out jane.crt \
  -days 365
```

Expected output:

```
Certificate request self-signature ok
subject=CN=jane, O=engineering
```

### Step 4: Inspect the certificate

Before using it, confirm the identity it carries:

```bash
openssl x509 -in jane.crt -noout -subject -dates
```

```
subject=CN=jane, O=engineering
notBefore=Apr 20 10:00:00 2026 GMT
notAfter=Apr 20 10:00:00 2027 GMT
```

One year from now, this certificate becomes invalid and must be replaced. There is no way to extend it — you have to issue a new one.

### Step 5: Build a kubeconfig entry for jane

```bash
# Get the cluster API server address from the current context
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# Create a kubeconfig for jane
kubectl config set-cluster k8s-security \
  --server=$APISERVER \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --kubeconfig=jane.kubeconfig

kubectl config set-credentials jane \
  --client-certificate=jane.crt \
  --client-key=jane.key \
  --embed-certs=true \
  --kubeconfig=jane.kubeconfig

kubectl config set-context jane@k8s-security \
  --cluster=k8s-security \
  --user=jane \
  --kubeconfig=jane.kubeconfig

kubectl config use-context jane@k8s-security \
  --kubeconfig=jane.kubeconfig
```

### Step 6: Test authentication — before RBAC

Try to list pods using jane's kubeconfig:

```bash
kubectl get pods --kubeconfig=jane.kubeconfig
```

```
Error from server (Forbidden): pods is forbidden: User "jane" cannot list
resource "pods" in API group "" in the namespace "default"
```

This is correct. Jane authenticated successfully — Kubernetes knows who she is. But she has no RBAC bindings, so every API call is denied. Authentication passed. Authorisation failed.

### Step 7: Grant jane access with RBAC

RBAC bindings use the username exactly as it appears in the certificate's CN field. If you need a refresher on how Roles, ClusterRoles, and RoleBindings work, this handbook on [How to Secure a Kubernetes Cluster: RBAC, Pod Hardening, and Runtime Protection](https://www.freecodecamp.org/news/how-to-secure-a-kubernetes-cluster-handbook/) covers the full RBAC model. For now, a simple RoleBinding using the built-in `view` ClusterRole is enough:

```yaml
# jane-rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jane-reader
subjects:
  - kind: User
    name: jane          # matches the CN in the certificate
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f jane-rolebinding.yaml
kubectl get pods --kubeconfig=jane.kubeconfig
```

```
No resources found in default namespace.
```

No error — jane can now list pods in `default`. She cannot delete them, create them, or access other namespaces. The certificate got her in. RBAC determines what she can do.

