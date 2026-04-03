
## How to Harden Pod Runtime Security

RBAC controls who can talk to the Kubernetes API. Pod security controls what containers can do once they're running on a node. These are different threat vectors: RBAC protects the control plane, pod security protects the data plane.

A container that runs as root with no capability restrictions can, if compromised:

*   Write to the host filesystem (dropping backdoors, modifying binaries)

*   Load kernel modules

*   Read other processes' memory if `hostPID: true` is set

*   In some configurations, escape the container entirely


Pod security closes these doors before an attacker can open them.

### A Case Study: The Hildegard Malware Campaign

In early 2021, Palo Alto's Unit 42 research team documented a cryptomining malware campaign called Hildegard that specifically targeted Kubernetes clusters. The attack chain was:

1.  Find a cluster with the kubelet API exposed without authentication

2.  Deploy a privileged pod with `hostPID: true`

3.  Use the privileged pod to read credentials from other containers' memory

4.  Establish persistence by writing to the host filesystem


Steps 3 and 4 would have been impossible if the pods in the cluster had been running with `readOnlyRootFilesystem: true`, dropped capabilities, and no `hostPID`. The attacker had the initial foothold. Pod security would have contained the blast radius.

### Pod Security Admission

Pod Security Admission (PSA) is the built-in admission controller that enforces pod security standards at the namespace level. It replaced PodSecurityPolicy in Kubernetes 1.25.

> **Migrating from PSP?** If you're on Kubernetes < 1.25, you may still be using PodSecurityPolicy, which was removed in 1.25. The migration path is: enable PSA in `audit` mode first to identify violations, fix them workload by workload, then switch to `enforce`. For policies PSA cannot express, add Kyverno alongside it.

PSA defines three profiles:

| Profile      | Who it's for                                       | What it restricts                                                                                      |
| ------------ | -------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `privileged` | System components (CNI plugins, monitoring agents) | Nothing — no restrictions                                                                              |
| `baseline`   | Most workloads                                     | Blocks known privilege escalations: no `hostNetwork`, no `hostPID`, no privileged containers           |
| `restricted` | Security-sensitive workloads                       | Everything in baseline, plus: must run as non-root, must drop capabilities, must set a seccomp profile |

And three enforcement modes:

| Mode      | Effect                                              | When to use                                                |
| --------- | --------------------------------------------------- | ---------------------------------------------------------- |
| `enforce` | Rejects pods that violate the profile at admission  | Production — once you've fixed violations                  |
| `audit`   | Allows pods but records violations in the audit log | Migration — see what would break without breaking anything |
| `warn`    | Allows pods but sends a warning to the client       | Development — fast feedback in your terminal               |

The migration path: start with `audit` and `warn` to identify violations, fix them, then switch to `enforce`. The two modes can run simultaneously.

## Demo 4 — Harden a Pod with securityContext

You'll start with a default nginx deployment, observe the PSA violations it triggers, harden it step by step, and confirm it passes under the `restricted` profile.

### Step 1: Apply PSA labels in audit mode

```bash
kubectl label namespace staging \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

### Step 2: Deploy insecure nginx and observe the warnings

```yaml
# insecure-nginx.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-insecure
  namespace: staging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-insecure
  template:
    metadata:
      labels:
        app: nginx-insecure
    spec:
      containers:
        - name: nginx
          image: nginx:1.25-alpine
```

```bash
kubectl apply -f insecure-nginx.yaml
```

Expected output (PSA warns but still creates the deployment in `warn` mode):

```
Warning: would violate PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (container "nginx" must set
    securityContext.allowPrivilegeEscalation=false)
  unrestricted capabilities (container "nginx" must set
    securityContext.capabilities.drop=["ALL"])
  runAsNonRoot != true (pod or container "nginx" must set
    securityContext.runAsNonRoot=true)
  seccompProfile not set (pod or container "nginx" must set
    securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/nginx-insecure created
```

Four violations. Every one of them is a real security gap. But the pod was still created "deployment.apps/nginx-insecure created"

### Step 3: Deploy the hardened version

```bash
kubectl apply -f secure-deployment.yaml   # the YAML from the securityContext section above
```

No warnings this time.

### Step 4: Switch the namespace to enforce

```bash"
kubectl label namespace staging \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest"
```

Expected output:

```
namespace/staging labeled
```

This is the moment enforcement becomes active. Any new pod that violates the `restricted` profile will be rejected from this point on.

### Step 5: Confirm insecure deployments are now rejected

```bash
kubectl delete deployment nginx-insecure -n staging
kubectl apply -f insecure-nginx.yaml
```

Expected output:

```
Warning: would violate PodSecurity "restricted:latest":
  allowPrivilegeEscalation != false (container "nginx" must set
    securityContext.allowPrivilegeEscalation=false)
  unrestricted capabilities (container "nginx" must set
    securityContext.capabilities.drop=["ALL"])
  runAsNonRoot != true (pod or container "nginx" must set
    securityContext.runAsNonRoot=true)
  seccompProfile (pod or container "nginx" must set
    securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
deployment.apps/nginx-insecure created
```

The Deployment object is created — PSA does not block Deployments. But check the ReplicaSet:

```bash
kubectl get replicaset -n staging -l app=nginx-insecure
```

```
NAME                       DESIRED   CURRENT   READY   AGE
nginx-insecure-b668d867b   1         0         0       30s
```

`DESIRED=1` but `CURRENT=0` — the ReplicaSet cannot create any pods because enforcement rejects them at admission. The `warn` label produces the warning you see on `kubectl apply`, while the `enforce` label silently blocks the actual pod creation.

The hardened deployment continues running. The insecure one has zero pods. This is exactly how PSA is supposed to work — enforcement happens at the **pod** level, not the Deployment level.

### Step 6: Score the hardened pod with kube-score

[kube-score](https://github.com/zegl/kube-score) is a static analysis tool that scores Kubernetes manifests against security and reliability best practices:

```bash
# macOS
brew install kube-score
# Linux: https://github.com/zegl/kube-score/releases

kube-score score secure-deployment.yaml -v
```

Expected output (abridged):

```
apps/v1/Deployment secure-app in staging 
  path=/Users/caesarsage/Documents/github.com/Learn-DevOps-by-building/intermediate/k8/security/04-security-admission/secure-deployment.yaml
    [OK] Stable version
    [OK] Label values
    [CRITICAL] Container Resources
        · app -> CPU limit is not set
            Resource limits are recommended to avoid resource DDOS. Set resources.limits.cpu
        · app -> Memory limit is not set
            Resource limits are recommended to avoid resource DDOS. Set resources.limits.memory
        · app -> CPU request is not set
            Resource requests are recommended to make sure that the application can start and run without crashing. Set resources.requests.cpu
        · app -> Memory request is not set
            Resource requests are recommended to make sure that the application can start and run without crashing. Set resources.requests.memory
    [CRITICAL] Container Image Pull Policy
        · app -> ImagePullPolicy is not set to Always
            It's recommended to always set the ImagePullPolicy to Always, to make sure that the imagePullSecrets are always correct, and to always get the image you want.
    [OK] Pod Probes Identical
    [CRITICAL] Container Ephemeral Storage Request and Limit
        · app -> Ephemeral Storage limit is not set
            Resource limits are recommended to avoid resource DDOS. Set resources.limits.ephemeral-storage
        · app -> Ephemeral Storage request is not set
            Resource requests are recommended to make sure the application can start and run without crashing. Set resource.requests.ephemeral-storage
    [OK] Environment Variable Key Duplication
    [OK] Container Security Context Privileged
    [OK] Pod Topology Spread Constraints
        · Pod Topology Spread Constraints
            No Pod Topology Spread Constraints set, kube-scheduler defaults assumed
    [OK] Container Image Tag
    [CRITICAL] Pod NetworkPolicy
        · The pod does not have a matching NetworkPolicy
            Create a NetworkPolicy that targets this pod to control who/what can communicate with this pod. Note, this feature needs to be supported by the CNI implementation used in the Kubernetes cluster to have an effect.
    [OK] Container Security Context User Group ID
    [OK] Container Security Context ReadOnlyRootFilesystem
    [CRITICAL] Deployment has PodDisruptionBudget
        · No matching PodDisruptionBudget was found
            It's recommended to define a PodDisruptionBudget to avoid unexpected downtime during Kubernetes maintenance operations, such as when draining a node.
    [WARNING] Deployment has host PodAntiAffinity
        · Deployment does not have a host podAntiAffinity set
            It's recommended to set a podAntiAffinity that stops multiple pods from a deployment from being scheduled on the same node. This increases availability in case the node becomes unavailable.
    [OK] Deployment Pod Selector labels match template metadata labels
```

Notice there are no security context violations — `securityContext`, `readOnlyRootFilesystem`, `seccompProfile`, and `runAsNonRoot` all pass. The remaining findings are about **resource management** (CPU/memory limits, ephemeral storage), **availability** (PodDisruptionBudget, anti-affinity), and **network policy** — not security context hardening. Those are important for production readiness, but they are a separate concern from the pod security hardening we did here.

