## How cert-manager Works

cert-manager is a Kubernetes operator. It extends the Kubernetes API with custom resources that represent certificate requests and their configuration. When you create a Certificate resource, cert-manager's controller picks it up, requests a certificate from the configured issuer, and stores the resulting certificate and private key in a Kubernetes Secret. When the certificate approaches its expiry, cert-manager renews it automatically.

This model means your application doesn't know or care about certificate management. It reads a Secret. cert-manager keeps that Secret fresh.

