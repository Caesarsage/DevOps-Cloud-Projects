# How to Harden Kubernetes End-to-End: Secrets, Supply Chain, and Compliance

Kubernetes Secrets are not encrypted by default. They are base64-encoded — which is encoding, not encryption. Anyone with `get` permission on Secrets in a namespace can read every credential stored there. And if they have access to the etcd backup, they can read all of them without going through the API at all.



## Demo 1 — Sync AWS Secrets Manager to Kubernetes with ESO

You'll install ESO, create a secret in AWS Secrets Manager, and watch ESO keep a Kubernetes Secret in sync with it — including automatic updates when the upstream secret changes.

### Step 1: Install ESO

ESO is currently at **v2.4.x**. Install via Helm:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait
```

Confirm the three ESO components are running:

```bash
kubectl get pods -n external-secrets
```

```plaintext
NAME                                               READY   STATUS    AGE
external-secrets-6d8b9f8d9-x8k2p                   1/1     Running   60s
external-secrets-cert-controller-7b9d8f-m9nqr       1/1     Running   60s
external-secrets-webhook-5c8b9f-j4tpw               1/1     Running   60s
```

### Step 2: Create a secret in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name production/database/password \
  --secret-string '{"username":"admin","password":"super-secret-db-password"}'
```

### Step 3: Create a ClusterSecretStore

This tells ESO how to connect to AWS Secrets Manager. For a kind cluster without IRSA, use static credentials stored in a Kubernetes Secret. In production on EKS, use IRSA instead — annotate the ESO service account with an IAM role ARN and remove the `auth.secretRef` block.

```bash
# Create a Secret holding the AWS credentials (dev/kind only — use IRSA in production)
kubectl create secret generic aws-credentials \
  --namespace external-secrets \
  --from-literal=access-key-id=YOUR_ACCESS_KEY_ID \
  --from-literal=secret-access-key=YOUR_SECRET_ACCESS_KEY
```

```yaml
# cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        secretRef:
          accessKeyIDSecretRef:
            name: aws-credentials
            namespace: external-secrets
            key: access-key-id
          secretAccessKeySecretRef:
            name: aws-credentials
            namespace: external-secrets
            key: secret-access-key
```

```bash
kubectl apply -f cluster-secret-store.yaml
kubectl get clustersecretstore aws-secrets-manager
```

```plaintext
NAME                   AGE   STATUS   CAPABILITIES   READY
aws-secrets-manager    5s    Valid    ReadWrite      True
```

`STATUS: Valid` means ESO connected to AWS Secrets Manager successfully.

### Step 4: Create an ExternalSecret

```yaml
# external-secret-db.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: database-credentials
  namespace: production
spec:
  refreshInterval: 1m           # Check for updates every minute
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: database-credentials  # The Kubernetes Secret to create
    creationPolicy: Owner       # ESO owns and manages this Secret
  data:
    - secretKey: username       # Key in the Kubernetes Secret
      remoteRef:
        key: production/database/password   # Path in Secrets Manager
        property: username                  # JSON field to extract
    - secretKey: password
      remoteRef:
        key: production/database/password
        property: password
```

```bash
kubectl create namespace production
kubectl apply -f external-secret-db.yaml
kubectl get externalsecret database-credentials -n production
```

```plaintext
NAME                   STORE                 REFRESH INTERVAL   STATUS    READY
database-credentials   aws-secrets-manager   1m                 SecretSynced   True
```

The Kubernetes Secret has been created:

```bash
kubectl get secret database-credentials -n production -o jsonpath='{.data.password}' | base64 -d
```

```plaintext
super-secret-db-password
```

### Step 5: Test automatic synchronisation

Update the secret in AWS Secrets Manager:

```bash
aws secretsmanager update-secret \
  --secret-id production/database/password \
  --secret-string '{"username":"admin","password":"rotated-password-123"}'
```

Wait one minute (the `refreshInterval`), then check the Kubernetes Secret:

```bash
kubectl get secret database-credentials -n production -o jsonpath='{.data.password}' | base64 -d
```

```plaintext
rotated-password-123
```

ESO detected the change and updated the Kubernetes Secret automatically. Your application, which mounts this Secret as a file or environment variable, can pick up the rotation on the next file read or pod restart.


> **Alternative backends:** ESO supports GCP Secret Manager, Azure Key Vault, HashiCorp Vault, 1Password, and many others. The `ClusterSecretStore` spec changes per provider, but the `ExternalSecret` spec is identical. See the [ESO provider documentation](https://external-secrets.io/latest/provider/aws-secrets-manager/) for provider-specific configuration. The companion repo includes `ClusterSecretStore` templates for GCP and Vault.

## How to Secure Your Software Supply Chain

### The Threat Model

The XZ Utils backdoor discovered in April 2024 came within weeks of being merged into major Linux distributions before a Microsoft engineer noticed something unusual in benchmark results. The attacker had spent two years establishing trust in the open-source project, gradually becoming a maintainer, before inserting a carefully hidden backdoor in the build system — not in the source code itself.

Kubernetes clusters are affected by supply chain attacks at multiple points: the base images your applications build from, the third-party packages those images contain, the CI pipeline that builds and pushes them, the container registry that stores them, and the Helm charts and operators you install into the cluster.

The OWASP Kubernetes Top 10 (2025) consolidates supply chain risk under K01 (insecure workload configurations) and K07 (misconfigured and vulnerable cluster components), reflecting how deeply supply chain compromise overlaps with the runtime security controls you've already applied. The four cluster-side controls that turn supply chain hygiene into enforced policy are: image signing at build time, signature verification at admission, SBOM generation and scanning, and registry allowlisting.

### How to Sign Images with Cosign

Cosign is part of the Sigstore project — a Linux Foundation initiative that provides free, open infrastructure for signing and verifying software artefacts. Cosign handles container images.

There are two signing modes. Key-based signing uses a long-lived key pair — you keep the private key and distribute the public key to anyone who needs to verify signatures. Keyless signing uses Sigstore's Fulcio CA, which issues a short-lived certificate tied to an OIDC identity (your GitHub Actions workflow, your Google account, your corporate IdP). The certificate and signature are recorded in Rekor, Sigstore's public transparency log, creating an immutable audit trail.

For CI pipelines, keyless signing is the better choice. There is no key to manage, rotate, or accidentally leak. Every signature is tied to the specific OIDC identity that signed it — the GitHub Actions workflow at a specific repository and git reference — and every signature is publicly verifiable via Rekor.

Signing an image in a GitHub Actions workflow:

```yaml
# .github/workflows/build-push-sign.yaml
- name: Build and push image
  uses: docker/build-push-action@v5
  with:
    push: true
    tags: ghcr.io/${{ github.repository }}:${{ github.sha }}

- name: Install Cosign
  uses: sigstore/cosign-installer@v3

- name: Sign the image
  run: |
    cosign sign --yes \
      ghcr.io/${{ github.repository }}:${{ github.sha }}
  env:
    COSIGN_EXPERIMENTAL: "true"
```

Verifying the signature:

```bash
cosign verify \
  --certificate-identity-regexp="https://github.com/your-org/your-repo" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/your-org/your-repo:abc1234
```

```plaintext
Verification for ghcr.io/your-org/your-repo:abc1234 --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - Existence of the claims in the transparency log was verified
  - The code-signing certificate claims were validated

[{"critical":{"identity":{"docker-reference":"ghcr.io/your-org/your-repo"},
"image":{"docker-manifest-digest":"sha256:..."},
"type":"cosign container image signature"},
"optional":{"1.3.6.1.4.1.57264.1.1":"https://token.actions.githubusercontent.com",
"Subject":"https://github.com/your-org/your-repo/.github/workflows/build.yaml@refs/heads/main"}}]
```

The signature is verified. You know the image was signed by a specific GitHub Actions workflow at a specific repository. Any image that wasn't signed by that workflow will fail verification.

### How to Enforce Signing at Admission with Kyverno

Verifying signatures manually is useful for debugging. Enforcing them at cluster admission is what actually prevents unsigned images from running.

Kyverno's `verifyImages` rule intercepts pod creation requests and verifies the signature of every container image before the pod is allowed to start. If the signature check fails, the pod is rejected:

```yaml
# kyverno-verify-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "ghcr.io/your-org/*"
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/your-org/*"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor:
                      url: https://rekor.sigstore.dev
```

With this policy active, any pod that tries to use an image from `ghcr.io/your-org/` must have a valid Cosign signature from a GitHub Actions workflow in your organisation. An image built locally and pushed directly, an image pulled from a different registry, or an image whose signature has been tampered with will all be rejected.

### How to Generate and Scan SBOMs

An SBOM — Software Bill of Materials — is a machine-readable inventory of every package in a container image. Generating one at build time gives you a record of what was in an image when it was built. Scanning it regularly tells you when a package in an image you already deployed develops a known vulnerability.

Syft generates SBOMs in standard formats:

```bash
# Install Syft
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin

# Generate an SBOM in SPDX format
syft ghcr.io/your-org/your-repo:abc1234 -o spdx-json > sbom.json
```

Scan the SBOM with Grype:

```bash
# Install Grype
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin

# Scan for vulnerabilities
grype sbom:./sbom.json
```

```plaintext
NAME         INSTALLED  FIXED-IN  TYPE  VULNERABILITY   SEVERITY
libssl3      3.1.4-r1   3.1.4-r5  apk   CVE-2024-0727   Medium
busybox      1.36.1-r2  (none)    apk   CVE-2023-42363  Low
```

For continuous in-cluster scanning, the Trivy Operator watches for new images deployed to the cluster and automatically generates vulnerability and compliance reports as Kubernetes custom resources:

```bash
helm repo add aquasecurity https://aquasecurity.github.io/helm-charts/
helm repo update

helm install trivy-operator aquasecurity/trivy-operator \
  --namespace trivy-system \
  --create-namespace \
  --wait
```

After installation, Trivy Operator creates `VulnerabilityReport` resources for every pod in the cluster. You can query them like any Kubernetes resource:

```bash
kubectl get vulnerabilityreports -n production
```

```plaintext
NAME                              SCANNER   AGE   CRITICAL   HIGH   MEDIUM   LOW
replicaset-myapp-7d4b9b-myapp     Trivy     5m    0          2      8        12
```



## Demo 2 — Sign an Image and Enforce the Signature at Admission

You'll build a simple image, sign it with Cosign, enforce the signature requirement with Kyverno, and verify that unsigned images are rejected.

### Step 1: Install Cosign

```bash
# macOS
brew install cosign

# Linux
curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign
```

### Step 2: Install Kyverno

```bash
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --wait
```

### Step 3: Generate a Cosign key pair

For a local demo, key-based signing is simpler than keyless (which requires an OIDC provider):

```bash
cosign generate-key-pair
```

This creates `cosign.key` (private) and `cosign.pub` (public). Keep `cosign.key` secret.

### Step 4: Push and sign a test image

```bash
# Use a public image for the demo
IMAGE="ttl.sh/cosign-demo-$(date +%s):1h"

# Pull, retag, and push a simple image to ttl.sh (ephemeral public registry)
docker pull alpine:latest
docker tag alpine:latest $IMAGE
docker push $IMAGE

# Sign it with your private key
cosign sign --key cosign.key $IMAGE
```

Expected output:

```plaintext
Pushing signature to: ttl.sh/cosign-demo-1234567890
```

Verify the signature:

```bash
cosign verify --key cosign.pub $IMAGE
```

```plaintext
Verification for ttl.sh/cosign-demo-1234567890:1h --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key
```

### Step 5: Create a Kyverno policy to enforce the signature

Store the public key as a Kubernetes Secret so Kyverno can reference it:

```bash
kubectl create secret generic cosign-public-key \
  --namespace kyverno \
  --from-file=cosign.pub=cosign.pub
```

```yaml
# kyverno-verify-signed.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: check-image-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - production
      verifyImages:
        - imageReferences:
            - "ttl.sh/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      <paste contents of cosign.pub here>
                      -----END PUBLIC KEY-----
```

```bash
kubectl apply -f kyverno-verify-signed.yaml
```

### Step 6: Test with a signed image

```bash
kubectl run signed-pod \
  --image=$IMAGE \
  --namespace production \
  --restart=Never
```

```plaintext
pod/signed-pod created
```

The signed image is admitted. Now test with an unsigned image:

### Step 7: Test with an unsigned image

```bash
UNSIGNED="ttl.sh/unsigned-demo-$(date +%s):1h"
docker pull nginx:alpine
docker tag nginx:alpine $UNSIGNED
docker push $UNSIGNED

kubectl run unsigned-pod \
  --image=$UNSIGNED \
  --namespace production \
  --restart=Never
```

Expected output:

```plaintext
Error from server: admission webhook "mutate.kyverno.svc-fail" denied the request:
resource Pod/production/unsigned-pod was blocked due to the following policies
require-signed-images:
  check-image-signature: failed to verify image ttl.sh/unsigned-demo-xxx:1h:
  .attestors[0].entries[0].keys: no signatures found
```

The unsigned image is blocked at admission. The signed image runs. Kyverno is doing exactly what you want: enforcing the supply chain boundary at the cluster entry point.


## How to Configure Kubernetes Audit Logging

Kubernetes generates an audit log for every request that reaches the API server. By default, audit logging is disabled. When you enable it, you get a structured record of who made what request, when, from which IP, and whether it succeeded.

Audit logs are the most important forensic resource when investigating a security incident. They answer questions like: when was this service account first used? who created this pod? who accessed that secret? who bound cluster-admin to this service account?

Audit logging is configured with a policy file that specifies what to log and at what level. There are four levels: `None` (don't log), `Metadata` (log request metadata but not the body), `Request` (log metadata and request body), and `RequestResponse` (log everything including the response body).

A minimal but useful audit policy:

```yaml
# audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  # Log secret access at RequestResponse level — you want to see the content
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["secrets"]

  # Log pod exec and port-forward at metadata level
  - level: Metadata
    resources:
      - group: ""
        resources: ["pods/exec", "pods/portforward", "pods/attach"]

  # Log auth changes at RequestResponse level
  - level: RequestResponse
    resources:
      - group: "rbac.authorization.k8s.io"
        resources: ["clusterrolebindings", "rolebindings"]

  # Log serviceaccount token creation
  - level: Metadata
    resources:
      - group: ""
        resources: ["serviceaccounts/token"]

  # Log everything else at Metadata level
  - level: Metadata
    omitStages:
      - RequestReceived   # Skip the initial request stage to reduce noise
```

Pass the policy to the API server with:

```bash
--audit-policy-file=/etc/kubernetes/audit-policy.yaml
--audit-log-path=/var/log/kubernetes/audit.log
--audit-log-maxage=30       # Keep 30 days of logs
--audit-log-maxbackup=10    # Keep 10 rotated log files
--audit-log-maxsize=100     # Rotate at 100MB
```

**Five events to always alert on:**

When shipping audit logs to a SIEM, these are the events that should generate immediate alerts in any production cluster:

`get` or `list` on `secrets` by any service account that shouldn't be reading secrets. Any `verb` on `clusterrolebindings` that creates a new binding to `cluster-admin`. `exec` into pods in the `kube-system` namespace. Deletion of audit log files or disabling of audit logging itself. Creation of `serviceaccount/token` resources outside of known automation — this is how an attacker mints persistent API tokens after gaining initial access.

## How to Measure Compliance with kube-bench and Trivy

### kube-bench

kube-bench runs the CIS Kubernetes Benchmark against your cluster configuration and reports which checks pass and fail. It checks the API server configuration, the controller manager, the scheduler, etcd, and the kubelet on each node.

```bash
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
kubectl wait --for=condition=complete job/kube-bench --timeout=120s
kubectl logs job/kube-bench | tail -20
```

```plaintext
== Summary master ==
51 checks PASS
 3 checks FAIL
 6 checks WARN
 0 checks INFO

== Summary node ==
22 checks PASS
 1 checks FAIL
 3 checks WARN
 0 checks INFO
```

If you ran kube-bench at the start of this series, compare these numbers now. The controls applied across these five articles — RBAC hardening, PSA enforcement, securityContext, audit logging, etcd encryption — correspond to specific CIS checks. The improvement in the PASS count is measurable.

To output the results as JSON for CI integration:

```bash
kubectl logs job/kube-bench | grep -A 1000 '\[' | python3 -c "
import sys, json
data = sys.stdin.read()
# Parse and check failure count
print(data)
"
```

Or use a dedicated kube-bench Job that outputs JSON:

```bash
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-json
spec:
  template:
    spec:
      hostPID: true
      containers:
        - name: kube-bench
          image: aquasec/kube-bench:latest
          command: ["kube-bench", "--json"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
      restartPolicy: Never
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
EOF
```

### Trivy for cluster-wide compliance

Trivy now includes CIS Kubernetes Benchmark scanning alongside its container image scanning, making it a more comprehensive option than kube-bench alone. It also covers the NSA/CISA Kubernetes Hardening Guide and runs as a persistent operator for continuous scanning:

```bash
# One-shot cluster compliance scan with Trivy CLI
trivy k8s cluster --compliance k8s-cis

# Or install the Trivy Operator for continuous scanning
helm install trivy-operator aquasecurity/trivy-operator \
  --namespace trivy-system \
  --create-namespace \
  --wait

# Query the compliance report
kubectl get clustercompliancereport cis -o yaml
```

Trivy Operator runs compliance scans every six hours by default and stores the results as Kubernetes custom resources, making them queryable, persistent, and diffable over time.


