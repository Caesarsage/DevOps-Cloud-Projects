# Monitoring and Managing the Canary Deployment

## Monitor the Canary Deployment
- Check canary pod logs:
  ```sh
  kubectl logs -l app=canary-demo,track=canary --tail=50
  ```
- Watch pod status:
  ```sh
  kubectl get pods -l app=canary-demo -w
  ```
- Check resource usage (requires metrics-server):
  ```sh
  kubectl top pods -l app=canary-demo
  ```

## Adjusting Traffic Distribution
- Scale canary up:
  ```sh
  kubectl scale deployment/canary-demo-canary --replicas=2
  ```
- Scale stable down:
  ```sh
  kubectl scale deployment/canary-demo-stable --replicas=0
  ```

## Rollout Completion
- Scale canary to full:
  ```sh
  kubectl scale deployment/canary-demo-canary --replicas=3
  ```
- Remove stable:
  ```sh
  kubectl delete deployment canary-demo-stable
  ```

## Rollback
- Scale down canary:
  ```sh
  kubectl scale deployment/canary-demo-canary --replicas=0
  ```
- Scale up stable:
  ```sh
  kubectl scale deployment/canary-demo-stable --replicas=3
  ```
