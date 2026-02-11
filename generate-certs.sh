#!/bin/bash
set -e

SERVICE_NAME="telltale"
NAMESPACE="dyc-back-dev"
CERTS_DIR="certs"
mkdir -p "${CERTS_DIR}"

echo "Generating TLS certificates for ${SERVICE_NAME}..."

# 1. Generate CA
openssl genrsa -out "${CERTS_DIR}/ca.key" 2048
openssl req -x509 -new -nodes -key "${CERTS_DIR}/ca.key" -subj "/CN=${SERVICE_NAME}-ca" -days 3650 -out "${CERTS_DIR}/ca.crt"

# 2. Generate Server Cert
openssl genrsa -out "${CERTS_DIR}/tls.key" 2048
cat > "${CERTS_DIR}/csr.conf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${SERVICE_NAME}
DNS.2 = ${SERVICE_NAME}.${NAMESPACE}
DNS.3 = ${SERVICE_NAME}.${NAMESPACE}.svc
DNS.4 = ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local
EOF

openssl req -new -key "${CERTS_DIR}/tls.key" -subj "/CN=${SERVICE_NAME}.${NAMESPACE}.svc" -out "${CERTS_DIR}/tls.csr" -config "${CERTS_DIR}/csr.conf"
openssl x509 -req -in "${CERTS_DIR}/tls.csr" -CA "${CERTS_DIR}/ca.crt" -CAkey "${CERTS_DIR}/ca.key" -CAcreateserial -out "${CERTS_DIR}/tls.crt" -days 365 -extensions v3_req -extfile "${CERTS_DIR}/csr.conf"

# 3. Create Secrets directly
echo "Creating TLS Secret..."
# Ensure namespace exists (or create it manually first with: oc create ns telltale)
# kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls ${SERVICE_NAME}-tls --cert="${CERTS_DIR}/tls.crt" --key="${CERTS_DIR}/tls.key" -n ${NAMESPACE} --dry-run=client -o yaml > k8s/${SERVICE_NAME}-tls.yaml

# 4. Patch Webhook CA Bundle
echo "Patching Webhook CA Bundle..."
CA_BUNDLE=$(cat "${CERTS_DIR}/ca.crt" | base64 | tr -d '\n')
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s|caBundle: \"\"|caBundle: ${CA_BUNDLE}|g" "k8s/validatingwebhook.yaml"
else
    sed -i "s|caBundle: \"\"|caBundle: ${CA_BUNDLE}|g" "k8s/validatingwebhook.yaml"
fi

echo "Certificates generated and configured!"