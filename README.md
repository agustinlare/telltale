# TellTale - Kubernetes Delete Notifier

A **ValidatingWebhook** for Kubernetes that sends notifications by email, Webhook or Microsoft Teams when Namespaces or ArgoCD Applications are deleted, indicating who performed the action.

> **TellTale**: For mismanaged clusters.

## Features

- Intercepts DELETE of **Namespaces**
- Intercepts DELETE of **ArgoCD Applications**
- Captures the **user or ServiceAccount** that performed the deletion
- Supports multiple transports: **Email (SMTP)**, **Webhook** (Discord/Slack) or **Microsoft Teams**
- **Does not block** the operation (always allows deletion)
- Excludes OpenShift system namespaces

## Prerequisites

-  Kubernetes 1.19+ or OpenShift 4.12+
- SMTP server, Webhook URL or Teams Webhook URL
- `oc` or `kubectl` with administrator permissions
- Docker/Podman to build the image
- OpenSSL to generate certificates

## Installation

### Step 1: Clone the repository

```bash
git clone <repository-url>
cd telltale
```

### Step 2: Create the Kubernetes Manifests

The `k8s/` directory is **not** part of this repository (it's git-ignored) because its contents are specific to your namespace, registry and secrets. Create it locally with the files below before continuing. They all default to the `telltale` namespace — change it consistently across every file (and via the `NAMESPACE` env var in Step 3) if you use a different one.

**`k8s/namespace.yaml`**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: telltale
```

**`k8s/serviceaccount.yaml`**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: telltale
  namespace: telltale
```

**`k8s/configmap.yaml`** — choose one transport:

Option A: Email (SMTP)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: telltale-config
  namespace: telltale
data:
  TRANSPORT_TYPE: "mail"
  CLUSTER_NAME: "<your-cluster-name>"
  SMTP_HOST: "smtp.domain.com"
  SMTP_PORT: "25"
  EMAIL_FROM: "[EMAIL_ADDRESS]"
  EMAIL_TO: "[EMAIL_ADDRESS]"
```

Option B: Webhook (Discord, Slack, etc.)
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: telltale-config
  namespace: telltale
data:
  TRANSPORT_TYPE: "webhook"
  CLUSTER_NAME: "<your-cluster-name>"
  WEBHOOK_URL: "https://discord.com/api/webhooks/..."
```

Option C: Microsoft Teams
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: telltale-config
  namespace: telltale
data:
  TRANSPORT_TYPE: "teams"
  CLUSTER_NAME: "<your-cluster-name>"
  WEBHOOK_URL: "https://outlook.office.com/webhook/..."
```

**`k8s/secret-smtp.yaml`** (optional — only if your SMTP server requires auth)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: telltale-smtp
  namespace: telltale
type: Opaque
stringData:
  SMTP_USER: ""
  SMTP_PASSWORD: ""
```

**`k8s/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: telltale
  namespace: telltale
  labels:
    app.kubernetes.io/name: telltale
spec:
  selector:
    app.kubernetes.io/name: telltale
  ports:
    - name: https
      port: 443
      targetPort: 8443
```

**`k8s/deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: telltale
  namespace: telltale
  labels:
    app.kubernetes.io/name: telltale
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: telltale
  template:
    metadata:
      labels:
        app.kubernetes.io/name: telltale
    spec:
      serviceAccountName: telltale
      containers:
        - name: webhook
          image: <your-registry>/telltale:latest
          ports:
            - containerPort: 8443
          envFrom:
            - configMapRef:
                name: telltale-config
            - secretRef:
                name: telltale-smtp
                optional: true
          volumeMounts:
            - name: tls
              mountPath: /certs
              readOnly: true
          securityContext:
            runAsNonRoot: true
            runAsUser: 1001
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: tls
          secret:
            secretName: telltale-tls
```

**`k8s/validatingwebhook.yaml`** — `caBundle: ""` is patched automatically by `generate-certs.sh` in the next step.
```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: telltale
  labels:
    app.kubernetes.io/name: telltale
webhooks:
  - name: namespace.delete.telltale.io
    admissionReviewVersions: ["v1"]
    sideEffects: NoneOnDryRun
    failurePolicy: Ignore  # Don't block deletions if the webhook fails
    matchPolicy: Equivalent
    timeoutSeconds: 5
    clientConfig:
      service:
        name: telltale
        namespace: telltale
        path: /validate
        port: 443
      caBundle: ""
    rules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["DELETE"]
        resources: ["namespaces"]
        scope: "Cluster"
    namespaceSelector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: NotIn
          values:
            - kube-system
            - kube-public
            - kube-node-lease
            - telltale
            # On OpenShift, also add the openshift-* system namespaces you
            # want to exclude (openshift, openshift-monitoring, openshift-etcd, etc.)

  - name: application.delete.telltale.io
    admissionReviewVersions: ["v1"]
    sideEffects: NoneOnDryRun
    failurePolicy: Ignore
    matchPolicy: Equivalent
    timeoutSeconds: 5
    clientConfig:
      service:
        name: telltale
        namespace: telltale
        path: /validate
        port: 443
      caBundle: ""
    rules:
      - apiGroups: ["argoproj.io"]
        apiVersions: ["v1alpha1"]
        operations: ["DELETE"]
        resources: ["applications"]
        scope: "Namespaced"
```

### Step 3: Generate and Configure TLS Certificates

Run the following script to generate certificates and patch the `caBundle` in `k8s/validatingwebhook.yaml`. Override `NAMESPACE`/`SERVICE_NAME` if you didn't use the defaults in Step 2.

```bash
chmod +x generate-certs.sh
NAMESPACE=telltale SERVICE_NAME=telltale ./generate-certs.sh
```

This creates `k8s/telltale-tls.yaml` (the TLS secret) and updates the `caBundle` fields in `k8s/validatingwebhook.yaml`.

### Step 4: Build the Docker Image

```bash
# Build the image
docker build -t telltale:latest .

# If you use a private registry:
docker tag telltale:latest <your-registry>/telltale:latest
docker push <your-registry>/telltale:latest
```

Update the `image:` field in `k8s/deployment.yaml` to match.

### Step 5: Deploy to the Cluster

```bash
# Apply all manifests
kubectl apply -f k8s/
```

### Step 6: Verify the Deployment

```bash
# Verify that the pods are running
kubectl get pods -n telltale

# View logs
kubectl logs -n telltale -l app.kubernetes.io/name=telltale -f
```

## Test the Functionality

1. Create a test namespace:
```bash
kubectl create namespace test-whistleblower
```

2. Delete the namespace:
```bash
kubectl delete namespace test-whistleblower
```

3. Verify the webhook logs:
```bash
kubectl logs -n telltale -l app.kubernetes.io/name=telltale --tail=50
```

4. Verify that the message was received through the configured medium.

## Project Structure

```
telltale/
├── Dockerfile                    # Container image
├── generate-certs.sh             # TLS cert generation + webhook patching
├── go.mod                        # Go dependencies
├── main.go                       # Application code
├── README.md                     # This documentation
└── k8s/                          # Not tracked in git (see Step 2) — create locally
    ├── namespace.yaml            # Webhook namespace
    ├── serviceaccount.yaml       # ServiceAccount
    ├── configmap.yaml            # Transport configuration
    ├── secret-smtp.yaml          # SMTP credentials (optional)
    ├── telltale-tls.yaml         # TLS secret (generated by generate-certs.sh)
    ├── deployment.yaml           # Application deployment
    ├── service.yaml              # Service
    └── validatingwebhook.yaml    # Webhook configuration
```

## Environment Variables

| Variable | Description | Default Value |
|----------|-------------|-------------------|
| `TRANSPORT_TYPE` | Transport type: `mail`, `webhook`, `teams` | `mail` |
| `CLUSTER_NAME` | Cluster name shown in notifications | `""` |
| `SMTP_HOST` | SMTP server (for `mail`) | `localhost` |
| `SMTP_PORT` | SMTP port (for `mail`) | `25` |
| `SMTP_USER` | SMTP user (optional) | `""` |
| `SMTP_PASSWORD` | SMTP password (optional) | `""` |
| `EMAIL_FROM` | Email sender address | `telltale@openshift.local` |
| `EMAIL_TO` | Email recipient address | `""` |
| `WEBHOOK_URL` | Webhook URL (for `webhook`/`teams`) | `""` |
| `TLS_CERT_FILE` | Path to the TLS certificate | `/certs/tls.crt` |
| `TLS_KEY_FILE` | Path to the TLS key | `/certs/tls.key` |

## Security

- The application runs as a non-root user (UID 1001)
- Read-only filesystem
- No privilege escalation
- Capabilities removed
- Seccomp profile RuntimeDefault
- TLS 1.2 minimum
