#!/bin/bash

# Delete the staging namespace and everything in it
kubectl delete namespace staging

# Delete Falco
helm uninstall falco -n falco
kubectl delete namespace falco

# Delete the kind cluster entirely
kind delete cluster --name k8s-security
