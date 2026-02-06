
# Canary Deployment on Kubernetes (kind)

>This project demonstrates a full canary deployment workflow on a local Kubernetes (kind) cluster, including traffic splitting with Envoy Gateway and monitoring/rollout management.

---

## Objectives
- Deploy a stable version of an application
- Deploy a canary version alongside the stable version
- Route traffic to both versions using a Service
- Split traffic using Envoy Gateway (weight-based and header-based)
- Monitor the canary deployment and manage rollout/rollback

## Directory Structure
- `application/canary/app-v1-deployment.yaml`: Stable deployment manifest
- `application/canary/app-v2-deployment.yaml`: Canary deployment manifest
- `application/canary/app-service.yaml`: Service manifest (basic)
- `manifests/canary-services.yaml.yaml`: Services for Envoy Gateway
- `manifests/envoy-gateway.yaml`: GatewayClass and Gateway for Envoy
- `manifests/httproute-weight.yaml`: HTTPRoute for weight-based traffic splitting
- `manifests/httproute-header.yaml`: HTTPRoute for header-based canary traffic
- `kind-cluster.yaml`: kind cluster configuration
- `monitoring.md`: Monitoring and rollout instructions

## Prerequisites
- Docker
- [kind](https://kind.sigs.k8s.io/) (Kubernetes IN Docker)
- kubectl
- helm (for Envoy Gateway)

---


## Step 1: Create a kind Cluster

```sh
kind create cluster --config kind-cluster.yaml
```
**Example output:**
```
Creating cluster "+kind+" ...
✓ Ensuring node image (kindest/node:...) ...
✓ Preparing nodes ...
✓ Writing configuration ...
✓ Starting control-plane ...
✓ Installing CNI ...
✓ Installing StorageClass ...
✓ Joining worker nodes ...
Set kubectl context to "kind-kind"
You can now use your cluster with:
kubectl cluster-info --context kind-kind
```

## Step 2: Deploy the Application


**Deploy the stable version:**
```sh
kubectl apply -f application/canary/app-v1-deployment.yaml
kubectl apply -f application/canary/app-service.yaml
```
**Example output:**
```
deployment.apps/rollout-demo-stable created
service/rollout-demo-service created
```

**Deploy the canary version:**
```sh
kubectl apply -f application/canary/app-v2-deployment.yaml
```
**Example output:**
```
deployment.apps/rollout-demo-canary created
```

## Step 3: (Optional) Traffic Splitting with Envoy Gateway


### 1. Install Envoy Gateway
```sh
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.6.2 -n envoy-gateway-system --create-namespace
```
**Example output:**
```
NAME: eg
NAMESPACE: envoy-gateway-system
STATUS: deployed
REVISION: 1
... (chart details)
```


### 2. Apply GatewayClass and Gateway
```sh
kubectl apply -f manifests/envoy-gateway.yaml
```
**Example output:**
```
gatewayclass.gateway.networking.k8s.io/envoy-gateway-class created
gateway.gateway.networking.k8s.io/envoy-gateway created
```


### 3. Apply Services and HTTPRoute
```sh
kubectl apply -f manifests/canary-services.yaml.yaml
kubectl apply -f manifests/httproute-weight.yaml   # For weight-based splitting
# OR
kubectl apply -f manifests/httproute-header.yaml   # For header-based canary
```
**Example output:**
```
service/canary-demo-stable-service created
service/canary-demo-canary-service created
httproute.gateway.networking.k8s.io/canary-demo-route created
```


### 4. Check Envoy Gateway Service
```sh
kubectl get svc -A | grep envoy
# Look for envoy-gateway or envoy-gateway-proxy (NodePort or LoadBalancer)
```
**Example output:**
```
envoy-gateway-system   envoy-gateway   NodePort   10.96.0.10   <none>   80:30080/TCP   5m
```


### 5. Port-forward and Test Traffic
```sh
kubectl port-forward -n envoy-gateway-system svc/envoy-gateway 8080:80 &
for i in {1..10}; do \
  curl -H "Host: canary-demo.example.com" http://localhost:8080/ ; \
done
```
**Example output:**
```
Forwarding from 127.0.0.1:8080 -> 80
Forwarding from [::1]:8080 -> 80
Hello, world! Version: v1
Hello, world! Version: v1
Hello, world! Version: v2
...etc
```
With a 90/10 split, about 1 in 10 requests should hit the canary.

---

## Step 4: Monitor and Manage the Rollout

See `monitoring.md` for full details. Common commands:


**Monitor canary pod logs:**
```sh
kubectl logs -l app.kubernetes.io/name=rollout-demo,track=canary --tail=50
```
**Example output:**
```
Hello, world! Version: v2
...
```

**Watch pod status:**
```sh
kubectl get pods -l app.kubernetes.io/name=rollout-demo -w
```
**Example output:**
```
NAME                                   READY   STATUS    RESTARTS   AGE
rollout-demo-stable-xxxxxxx-xxxxx      1/1     Running   0          2m
rollout-demo-canary-xxxxxxx-xxxxx      1/1     Running   0          1m
```

**Scale canary up:**
```sh
kubectl scale deployment/rollout-demo-canary --replicas=2
```
**Example output:**
```
deployment.apps/rollout-demo-canary scaled
```

**Scale stable down:**
```sh
kubectl scale deployment/rollout-demo-stable --replicas=0
```
**Example output:**
```
deployment.apps/rollout-demo-stable scaled
```

**Complete rollout:**
```sh
kubectl scale deployment/rollout-demo-canary --replicas=3
kubectl delete deployment rollout-demo-stable
```
**Example output:**
```
deployment.apps/rollout-demo-canary scaled
deployment.apps "rollout-demo-stable" deleted
```

**Rollback:**
```sh
kubectl scale deployment/rollout-demo-canary --replicas=0
kubectl scale deployment/rollout-demo-stable --replicas=3
```
**Example output:**
```
deployment.apps/rollout-demo-canary scaled
deployment.apps/rollout-demo-stable scaled
```

---

## Results and What to Expect

- **Initial traffic**: Most requests go to the stable version, a small percentage to canary (v2)
- **After scaling canary up**: More requests go to canary
- **After scaling stable down**: All traffic goes to canary
- **Header-based routing**: If using `httproute-header.yaml`, requests with `x-canary: true` go 100% to canary

**Sample curl output (weight-based):**
```
for i in {1..10}; do curl -H "Host: canary-demo.example.com" http://localhost:8080/ ; done
Hello, world! Version: v1
Hello, world! Version: v1
Hello, world! Version: v2
...
```

---

## References
- [Envoy Gateway Documentation](https://gateway.envoyproxy.io/latest/)
- [Kubernetes kind](https://kind.sigs.k8s.io/)

---
For detailed manifests and monitoring, see the referenced files in this directory.
