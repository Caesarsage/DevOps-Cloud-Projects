## Demo 1 — Install Cilium with SPIRE Integration

You'll create a kind cluster with Cilium as the CNI and enable its built-in SPIRE integration in a single Helm command.

### Step 1: Install the Cilium CLI

```bash
# macOS
brew install cilium-cli

# Linux
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar -xzf cilium-linux-amd64.tar.gz -C /usr/local/bin
```

### Step 2: Create a kind cluster without a default CNI

kind's default CNI (kindnet) must be disabled so Cilium can take its place. Save this as `kind-cilium.yaml`:

```yaml
# kind-cilium.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
networking:
  disableDefaultCNI: true   # Required: let Cilium be the CNI
  kubeProxyMode: none       # Cilium replaces kube-proxy too
```

```bash
kind create cluster --name k8s-mtls --config kind-cilium.yaml
```

The nodes will be in `NotReady` state until Cilium is installed — this is expected because there is no CNI yet.

### Step 3: Install Cilium with SPIRE enabled

Because Step 2 set `kubeProxyMode: none`, Cilium has to play the kube-proxy role itself — and that means its bootstrap pods can't reach the API server via the `kubernetes` Service ClusterIP, because nothing is routing it yet. You have to pass the API server's real address up front. Grab the kind control-plane's IP from Docker:

```bash
API_SERVER_IP=$(docker inspect k8s-mtls-control-plane \
  --format='{{ .NetworkSettings.Networks.kind.IPAddress }}')
echo "API_SERVER_IP=$API_SERVER_IP"
```

Then install Cilium with SPIRE:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade cilium cilium/cilium \
  --install \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=${API_SERVER_IP} \
  --set k8sServicePort=6443 \
  --set authentication.enabled=true \
  --set authentication.mutual.spire.enabled=true \
  --set authentication.mutual.spire.install.enabled=true \
  --set authentication.mutual.spire.install.server.dataStorage.enabled=false
```

A few of these flags are easy to miss but each is load-bearing:

- `kubeProxyReplacement=true` — Cilium installs its eBPF-based replacement for kube-proxy. Mandatory whenever the kind config sets `kubeProxyMode: none`.
- `k8sServiceHost` / `k8sServicePort` — direct API server address used during bootstrap, before Cilium can route the Service ClusterIP. On EKS/GKE/AKS you don't need this because kube-proxy is still present during install.
- `authentication.enabled=true` — required alongside `authentication.mutual.spire.enabled=true`. The chart's `validate.yaml` rejects the install with `SPIRE integration requires .Values.authentication.enabled=true and .Values.authentication.mutual.spire.enabled=true` if you set only the mutual flag.
- `dataStorage.enabled=false` — switches the SPIRE server from a PVC-backed datastore to in-memory. Fine for a lab cluster; in production leave this enabled and ensure your cluster has PersistentVolume support.

Notice there's no `--wait` flag here. On a fresh cluster `--wait` will appear to fail with `context deadline exceeded` because the install is racey by design: the SPIRE server has to schedule on a `NotReady` node thanks to its tolerations, then Cilium agents come up using SPIRE, then nodes flip to `Ready`. Let the install return immediately and watch the pods come up over the next ~2 minutes:

```bash
kubectl get pods -A -w
```

### Step 4: Verify the installation

```bash
cilium status --wait
```

```plaintext
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       disabled
    \__/       ClusterMesh:        disabled

DaemonSet              cilium             Desired: 3, Ready: 3/3, Available: 3/3
DaemonSet              cilium-envoy       Desired: 3, Ready: 3/3, Available: 3/3
Deployment             cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
```

Three Cilium agents — one per node, including the control-plane (no taints in the kind config). Check the SPIRE components in the `cilium-spire` namespace:

```bash
kubectl get all -n cilium-spire
```

```plaintext
NAME                    READY   STATUS    RESTARTS   AGE
pod/spire-agent-2cpsr   1/1     Running   0          3m
pod/spire-agent-klhjx   1/1     Running   0          3m
pod/spire-agent-vhsnc   1/1     Running   0          3m
pod/spire-server-0      2/2     Running   0          3m

NAME                              TYPE        CLUSTER-IP    PORT(S)    AGE
service/spire-server              ClusterIP   10.96.x.x     8081/TCP   3m

NAME                          DESIRED   CURRENT   READY   AGE
daemonset.apps/spire-agent    3         3         3       3m

NAME                             READY   AGE
statefulset.apps/spire-server    1/1     3m
```

One SPIRE agent per node. The SPIRE server is a StatefulSet with two containers — the server itself plus the SPIRE controller manager, which automatically creates workload registration entries for Cilium identities.

Run a health check on the SPIRE server:

```bash
kubectl exec -n cilium-spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server healthcheck
```

```plaintext
Server is healthy.
```

Verify the SPIRE agents have been attested:

```bash
kubectl exec -n cilium-spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server agent list
```

```plaintext
Found 3 attested agents:

SPIFFE ID         : spiffe://spiffe.cilium/spire/agent/k8s_psat/default/<node-uid-1>
Attestation type  : k8s_psat
Expiration time   : 2026-05-17 21:08:47 +0000 UTC
Serial number     : 91532884191503307904684123063465502141
Can re-attest     : true

SPIFFE ID         : spiffe://spiffe.cilium/spire/agent/k8s_psat/default/<node-uid-2>
...
```

Three agents, one per node, all attested via Kubernetes PSAT. The SPIRE server trusts every node and will issue SVIDs to workloads running on them.

## Demo 2 — Enforce Mutual TLS with a CiliumNetworkPolicy

Now you'll deploy two services, enforce mutual authentication between them with a `CiliumNetworkPolicy`, verify that authenticated traffic flows, and confirm that unauthenticated connections are blocked.

### Step 1: Deploy a client and server

This file contains both the server and the client — the client is a sleeping curl pod we'll use to exec into.

```yaml
# echo-workloads.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-server
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-server
  template:
    metadata:
      labels:
        app: echo-server
    spec:
      containers:
        - name: echo-server
          image: ealen/echo-server:latest
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: echo-server
  namespace: default
spec:
  selector:
    app: echo-server
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-client
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-client
  template:
    metadata:
      labels:
        app: echo-client
    spec:
      containers:
        - name: client
          image: curlimages/curl:latest
          command: ["sleep", "infinity"]
```

```bash
kubectl apply -f echo-workloads.yaml
# kubectl rollout status only takes one resource at a time
kubectl rollout status deployment/echo-server -n default
kubectl rollout status deployment/echo-client -n default
```

### Step 2: Confirm traffic flows without authentication

Before enforcing mTLS, confirm the client can reach the server:

```bash
CLIENT=$(kubectl get pod -l app=echo-client -o jsonpath='{.items[0].metadata.name}')
kubectl exec $CLIENT -- curl -s http://echo-server/
```

You should get a JSON response from the echo server. Traffic flows freely — no authentication.

### Step 3: Apply a CiliumNetworkPolicy requiring mutual authentication

Adding `authentication.mode: required` to a `CiliumNetworkPolicy` tells Cilium to enforce mutual TLS for matching traffic. Both sides of the connection must present a valid SPIFFE SVID:

```yaml
# mtls-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: echo-server-mtls
  namespace: default
spec:
  endpointSelector:
    matchLabels:
      app: echo-server
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: echo-client
      authentication:
        mode: required     # Require mutual TLS for this traffic
```

```bash
kubectl apply -f mtls-policy.yaml
```

### Step 4: Verify authenticated traffic still flows

```bash
kubectl exec $CLIENT -- curl -s http://echo-server/
```

The connection succeeds. Cilium intercepted it, performed the SPIFFE mTLS handshake between the Cilium agents on both pods' nodes, verified both SVIDs, and allowed the traffic through. The application on the client sent a plain HTTP request and received a response — the mutual authentication happened transparently at the network layer.

### Step 5: Observe the authentication with Hubble (optional)

Hubble is Cilium's observability layer. It needs its own CLI:

```bash
# macOS
brew install hubble

# Linux
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --remote-name-all \
  https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-amd64.tar.gz
sudo tar -xzf hubble-linux-amd64.tar.gz -C /usr/local/bin
```

Enable Hubble in the cluster, port-forward in the background, then watch flows:

```bash
cilium hubble enable
cilium hubble port-forward &

# Watch flows for the echo-server (Ctrl-C to stop)
hubble observe --namespace default --pod echo-server --follow
```

Trigger another request in a second terminal:

```bash
kubectl exec $CLIENT -- curl -s http://echo-server/
```

In the Hubble output you'll see:

```plaintext
TIMESTAMP   SOURCE                    DESTINATION              TYPE         VERDICT   REASON
10:23:41    default/echo-client       default/echo-server      L3/L4        ALLOWED   policy-verdict
10:23:41    default/echo-client       default/echo-server      HTTP         FORWARDED
```

The `ALLOWED` verdict with the `policy-verdict` reason confirms the CiliumNetworkPolicy matched and authentication was verified. No sidecar involved — this happened in the Cilium agents.

### Step 6: Verify that a pod without the matching label is blocked

Deploy a third pod without the `echo-client` label and try to reach the server:

```yaml
# unauthorized-client.yaml
apiVersion: v1
kind: Pod
metadata:
  name: unauthorized
  namespace: default
spec:
  containers:
    - name: client
      image: curlimages/curl:latest
      command: ["sleep", "infinity"]
```

```bash
kubectl apply -f unauthorized-client.yaml
kubectl exec unauthorized -- curl -s --max-time 5 http://echo-server/
```

```plaintext
curl: (28) Connection timed out after 5000 milliseconds
```

The connection times out. The `CiliumNetworkPolicy` only permits ingress from pods with `app: echo-client`. A pod without that label gets no SVID match and no policy match — Cilium drops the traffic silently.

### Step 7: Check the workload entries in SPIRE

Cilium's SPIRE controller manager automatically created SPIFFE identities for the Cilium security identities in this cluster. You can see them:

```bash
kubectl exec -n cilium-spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry show \
  -selector cilium:mutual-auth
```

Each entry maps a Cilium security identity to a SPIFFE ID. The Cilium operator manages this registry automatically — you never need to register workloads manually when using Cilium's built-in integration.

## Cloud Workload Identity

The SPIFFE/SPIRE model solves workload identity inside a Kubernetes cluster. AWS, GCP, and Azure have their own workload identity systems for giving pods access to cloud provider APIs — IAM roles, service accounts, managed identities. These cloud systems use OIDC federation under the hood, making them conceptually related to SPIFFE even though they operate at a different layer.

### AWS IRSA

IRSA — IAM Roles for Service Accounts — lets a Kubernetes service account assume an AWS IAM role without storing AWS credentials anywhere. The cluster acts as an OIDC provider. A pod's projected service account token is exchanged for temporary AWS credentials via AWS STS.

```yaml
# Annotate the Kubernetes service account
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  namespace: production
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/s3-reader-role
```

The trust policy on the IAM role specifies which Kubernetes service account can assume it:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::123456789:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub": "system:serviceaccount:production:s3-reader"
    }
  }
}
```

### GKE Workload Identity

GKE Workload Identity binds a Kubernetes service account to a Google Cloud service account. The pod receives a projected token that it can exchange for a GCP access token, giving it access to GCP APIs without storing a service account key anywhere.

```bash
# Bind the Kubernetes SA to the Google SA
gcloud iam service-accounts add-iam-policy-binding \
  my-app@my-project.iam.gserviceaccount.com \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:my-project.svc.id.goog[production/my-app]"

# Annotate the Kubernetes SA
kubectl annotate serviceaccount my-app \
  --namespace production \
  iam.gke.io/gcp-service-account=my-app@my-project.iam.gserviceaccount.com
```

### Azure Workload Identity

Azure Workload Identity uses OIDC federation between AKS and Azure AD. The pod gets a projected token that is exchanged for an Azure access token:

```bash
# Create a federated identity credential linking the K8s SA to the managed identity
az identity federated-credential create \
  --name my-app-federated \
  --identity-name my-managed-identity \
  --resource-group my-rg \
  --issuer "${AKS_OIDC_ISSUER}" \
  --subject "system:serviceaccount:production:my-app"

# Annotate the Kubernetes SA
kubectl annotate serviceaccount my-app \
  --namespace production \
  azure.workload.identity/client-id="${MANAGED_IDENTITY_CLIENT_ID}"
```

All three cloud workload identity systems follow the same pattern: a Kubernetes service account is associated with a cloud IAM identity, and the pod receives a short-lived projected token that the cloud provider accepts as proof of that association. The OIDC standard is the common thread. Understanding how SPIFFE SVIDs work — short-lived, cryptographically signed, audience-scoped — makes these cloud patterns immediately readable.

## Optional — Run This on EKS Instead of kind

The kind walkthrough above is the fastest way to see the demos work, but Cilium is a production CNI used at scale on EKS (Datadog, Adobe, and many others run it there). Three things change when you move from kind to EKS:

1. **You don't create the cluster with a config file.** You provision EKS via `eksctl` / Terraform / the AWS console, then reconfigure it for Cilium afterward.
2. **You have to remove the AWS VPC CNI and kube-proxy.** EKS ships with both by default. Cilium replaces both, so leaving them installed causes IP-allocation fights and double-routing.
3. **Different Cilium install flags.** EKS-specific networking (ENI mode for native AWS IP allocation, native routing instead of vxlan, plus the EKS API server address) replaces the kind-only `k8sServiceHost` / `k8sServicePort` block.

**Cost note:** EKS control plane is ~$0.10/hour (~$73/month if left running) plus EC2 worker nodes plus NAT gateway plus EBS for SPIRE storage. Budget ~$0.50–1.00 for a one-hour verification session. **Delete the cluster** when you're done.

### Provision EKS with the AWS VPC CNI disabled at the source

The cleanest path is to tell `eksctl` not to install the VPC CNI in the first place:

```yaml
# eks-cilium.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: cilium-mtls
  region: us-east-1
  version: "1.31"
nodeGroups:
  - name: workers
    instanceType: t3.medium
    desiredCapacity: 2
addons:
  - name: coredns
  - name: kube-proxy            # We'll delete this after creation
# Critically: do NOT include 'vpc-cni' here.
```

```bash
eksctl create cluster -f eks-cilium.yaml
```

(If you've already created the cluster with the VPC CNI installed, delete it with `kubectl -n kube-system delete daemonset aws-node` after the cluster is up.)

Delete `kube-proxy` so Cilium can replace it:

```bash
kubectl -n kube-system delete daemonset kube-proxy
```

### Install Cilium with EKS-specific flags

EKS gives you the API server hostname via your kubeconfig — extract it with `kubectl`:

```bash
API_SERVER_HOST=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' \
  | sed -E 's|https://([^:]+).*|\1|')
echo "API_SERVER_HOST=$API_SERVER_HOST"

helm upgrade cilium cilium/cilium \
  --install \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=${API_SERVER_HOST} \
  --set k8sServicePort=443 \
  --set eni.enabled=true \
  --set ipam.mode=eni \
  --set egressMasqueradeInterfaces=eth0 \
  --set routingMode=native \
  --set authentication.enabled=true \
  --set authentication.mutual.spire.enabled=true \
  --set authentication.mutual.spire.install.enabled=true
```

What's different from the kind install:

- `eni.enabled=true` + `ipam.mode=eni` — Cilium uses AWS ENI secondary IPs for pod addresses (the native EKS networking model). Without this, pods can't reach the internet via the VPC.
- `egressMasqueradeInterfaces=eth0` — SNATs pod-originated traffic so it goes out via the node's primary interface.
- `routingMode=native` — uses AWS VPC routing instead of vxlan tunneling. Faster, but requires the VPC CNI to be gone first.
- `k8sServicePort=443` — EKS uses 443, not 6443 like kind.
- **No `dataStorage.enabled=false`** — on EKS you want the default PVC-backed SPIRE storage (EKS comes with EBS CSI by default).

Cycle the existing workloads so they get re-IP'd by Cilium (the VPC CNI assigned their addresses before Cilium took over):

```bash
kubectl rollout restart deploy -n kube-system
```

After ~3 minutes, Cilium reports `OK` and SPIRE has attested the workers — both `cilium status` and the SPIRE `agent list` checks from Demo 1 Step 4 work identically.

### Clean up

```bash
helm uninstall cilium -n kube-system
kubectl delete namespace cilium-spire
eksctl delete cluster --name cilium-mtls --region us-east-1
```

The `eksctl delete cluster` step is the cost-sensitive one. Run it.

## Cleanup (kind)

```bash
# Delete demo workloads
kubectl delete deployment echo-server echo-client -n default
kubectl delete service echo-server -n default
kubectl delete pod unauthorized -n default
kubectl delete ciliumnetworkpolicy echo-server-mtls -n default

# Uninstall Cilium (helm doesn't delete the cilium-spire namespace it created)
helm uninstall cilium -n kube-system
kubectl delete namespace cilium-spire

# Delete the cluster (easiest reset on kind)
kind delete cluster --name k8s-mtls
```
