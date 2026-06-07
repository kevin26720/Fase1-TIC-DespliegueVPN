#!/bin/bash
# ==========================================
# Test PKI Generator for Hardened OpenVPN
# ==========================================
set -e

PKI_DIR="docker/config/pki"
CRL_DIR="docker/config/crl"

echo "[INFO] Creating PKI and CRL directories..."
mkdir -p "$PKI_DIR"
mkdir -p "$CRL_DIR"

# Working directory for OpenSSL database (relative path to avoid Windows path translation errors)
WORKDIR="./tmp_pki_build"
mkdir -p "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[INFO] Configuring temporary OpenSSL workspace..."
touch "$WORKDIR/index.txt"
echo 1000 > "$WORKDIR/serial"
echo 1000 > "$WORKDIR/crlnumber"

cat <<EOF > "$WORKDIR/openssl.cnf"
[ ca ]
default_ca = test_ca

[ test_ca ]
dir              = $WORKDIR
certs            = \$dir
crl_dir          = \$dir
database         = \$dir/index.txt
new_certs_dir    = \$dir
serial           = \$dir/serial
crlnumber        = \$dir/crlnumber
crl              = \$dir/crl.pem
private_key      = $PKI_DIR/ca.key
certificate      = $PKI_DIR/ca.crt
default_days     = 365
default_crl_days = 30
default_md       = sha256
preserve         = no
policy           = policy_strict

[ policy_strict ]
commonName             = supplied
stateOrProvinceName    = optional
countryName            = optional
emailAddress           = optional
organizationName       = optional
organizationalUnitName = optional

[ server_ext ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer:always
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature, keyAgreement
extendedKeyUsage       = serverAuth

[ client_ext ]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid,issuer:always
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = clientAuth
EOF

# 1. Generate CA Certificate
echo "[INFO] Generating CA private key and self-signed certificate..."
openssl genrsa -out "$PKI_DIR/ca.key" 4096
openssl req -new -x509 -days 3650 -key "$PKI_DIR/ca.key" -out "$PKI_DIR/ca.crt" \
    -subj "//CN=Hardened-OpenVPN-Test-CA"

# 2. Generate Diffie-Hellman Parameters (2048-bit for fast testing generation)
echo "[INFO] Generating Diffie-Hellman parameters (2048-bit)..."
openssl dhparam -out "$PKI_DIR/dh.pem" 2048

# 3. Generate tls-crypt Key
# Check if openvpn is available to generate a standard static key format
if command -v openvpn >/dev/null 2>&1; then
    echo "[INFO] Generating tls-crypt.key using local OpenVPN..."
    openvpn --genkey secret "$PKI_DIR/tls-crypt.key"
else
    echo "[WARNING] OpenVPN binary not found. Generating a mock static key for local simulation..."
    cat <<EOF > "$PKI_DIR/tls-crypt.key"
#
# 2048 bit OpenVPN static key
#
-----BEGIN OpenVPN Static key V1-----
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
-----END OpenVPN Static key V1-----
EOF
fi

# 4. Generate Node 1 Server Certificate
echo "[INFO] Generating Node 1 server certificate..."
openssl genrsa -out "$PKI_DIR/server-node1.key" 2048
openssl req -new -key "$PKI_DIR/server-node1.key" -out "$WORKDIR/server-node1.csr" \
    -subj "//CN=openvpn-node1"
openssl ca -config "$WORKDIR/openssl.cnf" -batch -extensions server_ext \
    -in "$WORKDIR/server-node1.csr" -out "$PKI_DIR/server-node1.crt"

# 5. Generate Node 2 Server Certificate
echo "[INFO] Generating Node 2 server certificate..."
openssl genrsa -out "$PKI_DIR/server-node2.key" 2048
openssl req -new -key "$PKI_DIR/server-node2.key" -out "$WORKDIR/server-node2.csr" \
    -subj "//CN=openvpn-node2"
openssl ca -config "$WORKDIR/openssl.cnf" -batch -extensions server_ext \
    -in "$WORKDIR/server-node2.csr" -out "$PKI_DIR/server-node2.crt"

# 6. Generate Client Certificate
echo "[INFO] Generating client certificate..."
openssl genrsa -out "$PKI_DIR/client.key" 2048
openssl req -new -key "$PKI_DIR/client.key" -out "$WORKDIR/client.csr" \
    -subj "//CN=test-client"
openssl ca -config "$WORKDIR/openssl.cnf" -batch -extensions client_ext \
    -in "$WORKDIR/client.csr" -out "$PKI_DIR/client.crt"

# 7. Generate Initial Certificate Revocation List (CRL)
echo "[INFO] Generating initial Certificate Revocation List (CRL)..."
openssl ca -config "$WORKDIR/openssl.cnf" -gencrl -out "$CRL_DIR/crl.pem"

echo "[SUCCESS] PKI initialization completed. Certificates generated in $PKI_DIR"
