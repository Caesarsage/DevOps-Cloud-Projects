# How to Implement Zero-Trust Workload Identity in Kubernetes with SPIFFE, SPIRE, and Cilium

Full Article link: 

## Prerequisites

*   Familiarity with Kubernetes RBAC and pod security — the [first handbook in this series](https://www.freecodecamp.org/news/how-to-secure-a-kubernetes-cluster-handbook/) covers the foundations

*   Familiarity with TLS certificates and Kubernetes Secrets — the [third handbook in this series](https://www.freecodecamp.org/news/how-to-encrypt-kubernetes-traffic/) covers cert-manager and certificate concepts

*   Helm 3 and the Cilium CLI installed

*   A kind cluster — you'll create a fresh one with Cilium as the CNI in this article

*   Patience: this is the most complex demo in the series. SPIRE has more moving parts than anything else covered so far


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

*   `kubeProxyReplacement=true` — Cilium installs its eBPF-based replacement for kube-proxy. Mandatory whenever the kind config sets `kubeProxyMode: none`.

*   `k8sServiceHost` / `k8sServicePort` — direct API server address used during bootstrap, before Cilium can route the Service ClusterIP. On EKS/GKE/AKS you don't need this because kube-proxy is still present during install.

*   `authentication.enabled=true` — required alongside `authentication.mutual.spire.enabled=true`. The chart's `validate.yaml` rejects the install with `SPIRE integration requires .Values.authentication.enabled=true and .Values.authentication.mutual.spire.enabled=true` if you set only the mutual flag.

*   `dataStorage.enabled=false` — switches the SPIRE server from a PVC-backed datastore to in-memory. Fine for a lab cluster; in production leave this enabled and ensure your cluster has PersistentVolume support.


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

At this point the identity platform is fully in place — but nothing is using it yet. Demo 1 built the machinery that *issues* cryptographic identities; Demo 2 puts that machinery to work, turning those SVIDs into an enforced mutual-TLS policy between two real services. Keep the cluster from Demo 1 running — Demo 2 builds directly on it.

## Demo 2 — Enforce Mutual TLS with a CiliumNetworkPolicy

Picking up in the same cluster from Demo 1, you'll deploy two services, enforce mutual authentication between them with a `CiliumNetworkPolicy`, verify that authenticated traffic flows, and confirm that unauthenticated connections are blocked. Every request here is authenticated with the SVIDs that the SPIRE server you just verified hands out — the two demos are one continuous walkthrough, not standalone exercises.

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

Enable Hubble in the cluster, then watch flows. `cilium hubble enable` deploys Hubble Relay *and* restarts the Cilium agents to switch on the Hubble server inside them — so wait for it to settle before port-forwarding. Skip the wait and the port-forward connects before Relay is listening, then dies with `connection reset by peer` / `rpc error … EOF`:

```bash
cilium hubble enable
cilium status --wait          # wait for "Hubble Relay: OK" before continuing

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

ℹ️  Hubble Relay is available at 127.0.0.1:4245
Jul  7 12:44:42.380: default/echo-client-86d446b8f-9bn5v:47500 (ID:2822) -> default/echo-server-7467b4b54d-5tvkz:80 (ID:30854) policy-verdict:none TRAFFIC_DIRECTION_UNKNOWN ALLOWED (TCP Flags: SYN)
Jul  7 12:44:42.380: default/echo-client-86d446b8f-9bn5v:47500 (ID:2822) -> default/echo-server-7467b4b54d-5tvkz:80 (ID:30854) to-endpoint FORWARDED (TCP Flags: SYN)
Jul  7 12:44:42.381: default/echo-client-86d446b8f-9bn5v:47500 (ID:2822) <- default/echo-server-7467b4b54d-5tvkz:80 (ID:30854) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
```

The `ALLOWED` verdict with the `policy-verdict` reason confirms the CiliumNetworkPolicy matched and authentication was verified. No sidecar involved — this happened in the Cilium agents.

**Prefer a graphical view? Enable the Hubble UI.** Everything above is the API + terminal path (Relay on port 4245 backs the `hubble` CLI). Hubble also ships a web dashboard with a live service map — but it's a separate component that `cilium hubble enable` does *not* start by default:

```bash
# Add the UI (re-runs enable, keeps Relay, adds the hubble-ui deployment)
cilium hubble enable --ui

# Wait for it to be Ready before opening — same race as Relay. Skip this and
# `cilium hubble ui` fails with "connection refused" on port 8081, because the
# UI's frontend container isn't listening yet.
kubectl -n kube-system rollout status deployment/hubble-ui --timeout=90s

# Port-forwards hubble-ui and opens http://localhost:12000 in your browser
cilium hubble ui
```

Select the **`default`** namespace from the dropdown — that's where the demo pods and the policy live. The map is *live*: it renders edges from flows as they happen, so an idle namespace looks empty. Trigger a request to light it up:

```bash
kubectl exec $CLIENT -- curl -s http://echo-server/
```

You'll see a forwarded edge `echo-client → echo-server`; click it (or open the flow table at the bottom) to read the `policy-verdict: ALLOWED`. Leave the UI open through Step 6 — when you run the unauthorized-client test there, its connection shows up as a red *dropped* edge, the visual counterpart to the `curl` timeout.

![Hubble UI — live service map for the `default` namespace, with forwarded and dropped flows](images/hubble-ui.png)

The UI has three parts. The **service map** at the top draws each workload identity as a box and each observed connection as an edge colored by verdict: `echo-client → echo-server:80` is a solid green (forwarded) edge, while the box labelled `default` — that's the `unauthorized` pod, which carries only the namespace identity because it has no `app` label, so Hubble names it after that — reaches `echo-server` over a red dashed (dropped) line, and the 🔒 lock on `echo-server`'s `→ 80 TCP` port marks that endpoint as mutually authenticated by the policy. The **flow table** underneath logs one row per flow — source identity, destination identity, destination port, L7 info, `Verdict`, and timestamp — so you can read both outcomes side by side, with `echo-client → echo-server` rows marked **forwarded** and `default → echo-server` rows marked **dropped**: the same allow/deny split as the CLI, one line per packet. The **top bar** holds the namespace selector, a flow filter, the `Any verdict` / `Visual` toggle, and a live `flows/s` rate alongside the count of reporting nodes (`3/3`).

> Save the screenshot as `images/hubble-ui.png` next to this README for the image above to render.

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
kubectl wait --for=condition=Ready pod/unauthorized --timeout=60s
kubectl exec unauthorized -- curl -sS --max-time 5 http://echo-server/
```

```plaintext
curl: (28) Connection timed out after 5000 milliseconds
```

The connection times out. The `CiliumNetworkPolicy` only permits ingress from pods with `app: echo-client`. A pod without that label gets no SVID match and no policy match — Cilium drops the traffic silently.

> **Two gotchas here.** Run `kubectl wait` before exec — exec too soon after `apply` and you get `container not found ("client")` because the pod's container hasn't started yet. And use `curl -sS`, not plain `-s`: with only `-s`, curl swallows the error text and you just see `command terminated with exit code 28`. That's the same result — 28 *is* curl's timeout code — but the `-S` restores the readable message. The fact that it **times out** (rather than "connection refused") is the signature of a policy *drop*: the packets are silently blackholed, not actively rejected. A refusal would return instantly with a different error.

### Step 7: Check the workload entries in SPIRE

Cilium's SPIRE controller manager automatically created SPIFFE identities for the Cilium security identities in this cluster. You can see them:

```bash
kubectl exec -n cilium-spire spire-server-0 -c spire-server -- \
  /opt/spire/bin/spire-server entry show \
  -selector cilium:mutual-auth
```

Each entry maps a Cilium security identity to a SPIFFE ID. The Cilium operator manages this registry automatically — you never need to register workloads manually when using Cilium's built-in integration.

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
