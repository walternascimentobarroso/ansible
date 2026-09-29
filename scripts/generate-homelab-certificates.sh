#!/usr/bin/env bash

set -euo pipefail

DOMAIN="${HOMELAB_DOMAIN:-home.arpa}"

CERTS_DIR="certs/homelab"
CA_DIR="${CERTS_DIR}/ca"
TRAEFIK_DIR="${CERTS_DIR}/traefik"

CA_KEY="${CA_DIR}/homelab-root-ca.key"
CA_CERT="${CA_DIR}/homelab-root-ca.crt"

TLS_KEY="${TRAEFIK_DIR}/${DOMAIN}.key"
TLS_CSR="${TRAEFIK_DIR}/${DOMAIN}.csr"
TLS_CERT="${TRAEFIK_DIR}/${DOMAIN}.crt"
TLS_EXT="${TRAEFIK_DIR}/${DOMAIN}.ext"

echo "==> Creating directories"
mkdir -p "${CA_DIR}" "${TRAEFIK_DIR}"

#
# Root CA
#

if [[ ! -f "${CA_KEY}" ]]; then
    echo "==> Generating Homelab Root CA private key"
    openssl genrsa \
        -out "${CA_KEY}" \
        4096

    chmod 600 "${CA_KEY}"
else
    echo "==> Root CA private key already exists"
fi

if [[ ! -f "${CA_CERT}" ]]; then
    echo "==> Generating Homelab Root CA certificate"
    openssl req \
        -x509 \
        -new \
        -sha256 \
        -days 3650 \
        -key "${CA_KEY}" \
        -out "${CA_CERT}" \
        -subj "/CN=Homelab Root CA"
else
    echo "==> Root CA certificate already exists"
fi

#
# Traefik certificate
#
# home.arpa is on the Public Suffix List, so Apple's TLS stack rejects a
# *.home.arpa wildcard. Every host exposed by Traefik is listed explicitly.

HOSTS=$(grep -ho 'Host(`[^.]*' roles/traefik/templates/*.j2 | cut -d'`' -f2 | sort -u)

echo "==> Generating Traefik private key"

openssl genrsa \
    -out "${TLS_KEY}" \
    2048

chmod 600 "${TLS_KEY}"

echo "==> Generating certificate request"

openssl req \
    -new \
    -key "${TLS_KEY}" \
    -out "${TLS_CSR}" \
    -subj "/CN=${DOMAIN}"

echo "==> Creating certificate extensions"

cat > "${TLS_EXT}" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names

[alt_names]
DNS.1=${DOMAIN}
EOF

index=2
for host in ${HOSTS}; do
    echo "DNS.${index}=${host}.${DOMAIN}" >> "${TLS_EXT}"
    index=$((index + 1))
done

echo "==> Signing certificate with Homelab Root CA"

openssl x509 \
    -req \
    -sha256 \
    -days 825 \
    -in "${TLS_CSR}" \
    -CA "${CA_CERT}" \
    -CAkey "${CA_KEY}" \
    -CAcreateserial \
    -out "${TLS_CERT}" \
    -extfile "${TLS_EXT}"

#
# Cleanup
#

echo "==> Cleaning temporary files"

rm -f \
    "${TLS_CSR}" \
    "${TLS_EXT}" \
    "${CA_DIR}/homelab-root-ca.srl"

#
# Validation
#

echo
echo "==> Verifying certificate"

openssl verify \
    -CAfile "${CA_CERT}" \
    "${TLS_CERT}"

echo
echo "==> Certificate information"

openssl x509 \
    -in "${TLS_CERT}" \
    -noout \
    -subject \
    -issuer \
    -dates \
    -ext subjectAltName

echo
echo "Certificates generated successfully."
echo
echo "Root CA:"
echo "  ${CA_CERT}"
echo
echo "Traefik certificate:"
echo "  ${TLS_CERT}"
echo
echo "Traefik private key:"
echo "  ${TLS_KEY}"