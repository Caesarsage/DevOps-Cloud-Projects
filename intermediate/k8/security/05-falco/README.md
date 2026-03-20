
## Demo 5 — Deploy Falco and Write a Custom Detection Rule

You'll deploy Falco in eBPF mode, trigger a default alert, then extend Falco with a custom rule that catches `curl` and `wget` being run inside containers.

### Step 1: Install Falco via Helm

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --wait
```

Confirm Falco is running on every node:

```shell
kubectl get pods -n falco
```

```shell
NAME           READY   STATUS    RESTARTS   AGE
falco-x8k2p    1/1     Running   0          45s
falco-m9nqr    1/1     Running   0          45s
falco-j4tpw    1/1     Running   0          45s
```

One pod per node — Falco runs as a DaemonSet because it needs to monitor syscalls on every node independently.

### Step 2: Trigger a default alert

Open a second terminal and stream the Falco logs:

```shell
# Terminal 2 — watch for alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f --max-log-requests 3
```

In your first terminal, exec into the secure-app pod:

```bash
# Terminal 1 — trigger the shell detection
POD=$(kubectl get pod -n staging -l app=secure-app \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n staging -- sh
```

Within a second, Terminal 2 shows:

```plaintext
2024-03-15T14:23:41.456Z: Notice A shell was spawned in a container with an attached terminal
  (user=root user_loginuid=-1 k8s.ns=staging k8s.pod=secure-app-7d9f8b-xxx
   container=app shell=sh parent=runc cmdline=sh terminal=34816)
  rule=Terminal shell in container  priority=NOTICE
  tags=[container, shell, mitre_execution]
```

This is Falco's built-in `Terminal shell in container` rule firing. It detected the `kubectl exec` session the moment you ran it.

### Step 3: Write a custom rule

The built-in rules are comprehensive, but every production environment has workloads with unique behaviour. Here is a custom rule that alerts when `curl` or `wget` is executed inside any container:

```yaml
# custom-rules.yaml
customRules:
  custom-rules.yaml: |-
    - rule: Suspicious network tool in container
      desc: >
        Detects execution of curl or wget inside a running container.
        These tools are commonly used for data exfiltration, downloading
        attacker payloads, or reaching command-and-control servers.
        Production containers should not be making ad-hoc HTTP requests.
      condition: >
        spawned_process
        and container
        and proc.name in (curl, wget)
      output: >
        Network tool executed in container
        (user=%user.name tool=%proc.name cmd=%proc.cmdline
         pod=%k8s.pod.name ns=%k8s.ns.name image=%container.image)
      priority: WARNING
      tags: [network, exfiltration, custom]
```

Apply it by upgrading the Helm release:

```bash
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  -f custom-rules.yaml \
  --wait
```

### Step 4: Test the custom rule

```bash
# Terminal 1 — run curl inside the container
kubectl exec -it $POD -n staging -- sh -c 'curl https://example.com'
```

Terminal 2 immediately shows:

```plaintext
2024-03-15T14:31:07.812Z: Warning Network tool executed in container
  (user=root tool=curl cmd=curl https://example.com
   pod=secure-app-7d9f8b-xxx ns=staging image=nginx:1.25-alpine)
  rule=Suspicious network tool in container  priority=WARNING
  tags=[network, exfiltration, custom]
```

### Step 5: Route alerts to Slack with Falcosidekick

Streaming logs is useful during development. In production, you need alerts routed to your alerting pipeline. Falcosidekick handles this with support for Slack, PagerDuty, Datadog, Elasticsearch, and over 50 other outputs:

```yaml
# falcosidekick-values.yaml
config:
  slack:
    webhookurl: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
    minimumpriority: "warning"
    messageformat: >
      [{{.Priority}}] {{.Rule}} |
      pod: {{.OutputFields.k8s.pod.name}} |
      ns: {{.OutputFields.k8s.ns.name}} |
      image: {{.OutputFields.container.image}}
```

```bash
helm install falcosidekick falcosecurity/falcosidekick \
  --namespace falco \
  -f falcosidekick-values.yaml
```

> **Tuning Falco for production:** A fresh Falco deployment will generate false positives, especially in the first week. Your job is to tune rules to match your workloads' normal behaviour, not to respond to every alert. The workflow: deploy in staging → identify false positives → add `except` conditions to rules → validate the false positive rate is low → enable in production with alerting.
