#!/bin/bash
# ==========================================================
# DevSecOps Config Linter & Compliance Dashboard Generator
# ==========================================================

FAILED=0
HTML_FILE="tests/compliance-dashboard.html"
MD_FILE="tests/compliance-summary.md"

# Arrays to keep track of checks
RULES=()
CATEGORIES=()
STATUSES=()
DETAILS=()

add_check_result() {
    local category=$1
    local rule=$2
    local status=$3 # "PASSED" or "FAILED"
    local detail=$4
    
    CATEGORIES+=("$category")
    RULES+=("$rule")
    STATUSES+=("$status")
    DETAILS+=("$detail")

    if [ "$status" == "FAILED" ]; then
        FAILED=1
    fi
}

check_file_contains() {
    local category=$1
    local rule=$2
    local file=$3
    local pattern=$4
    local err_msg=$5
    local ok_msg=$6

    if grep -qE -- "$pattern" "$file" 2>/dev/null; then
        add_check_result "$category" "$rule" "PASSED" "$ok_msg"
    else
        add_check_result "$category" "$rule" "FAILED" "$err_msg"
    fi
}

check_file_does_not_contain() {
    local category=$1
    local rule=$2
    local file=$3
    local pattern=$4
    local err_msg=$5
    local ok_msg=$6

    if grep -qE -- "$pattern" "$file" 2>/dev/null; then
        add_check_result "$category" "$rule" "FAILED" "$err_msg"
    else
        add_check_result "$category" "$rule" "PASSED" "$ok_msg"
    fi
}

echo "=== Running Policy as Code Audits ==="

# 1. Audit OpenVPN Server Configuration files
for config in docker/config/server-node1.conf docker/config/server-node2.conf; do
    node_name=$(basename "$config" .conf)
    
    # Cipher AES-256-GCM
    check_file_contains "Criptografía" "Cifrado GCM ($node_name)" "$config" "^cipher[[:space:]]+AES-256-GCM" \
        "Falta cipher AES-256-GCM en configuración." \
        "Confirmado: AES-256-GCM está activo."

    # TLS Version Min
    check_file_contains "Criptografía" "TLS Mínimo ($node_name)" "$config" "^tls-version-min[[:space:]]+1.2" \
        "Falta tls-version-min 1.2 en configuración." \
        "Confirmado: TLS v1.2 mínimo configurado."

    # Control Channel Encryption (tls-crypt)
    check_file_contains "Mitigación DoS" "Canal de Control ($node_name)" "$config" "^tls-crypt" \
        "Falta tls-crypt para cifrar metadatos del handshake." \
        "Confirmado: tls-crypt está configurado."

    # Block legacy ciphers (Blowfish check)
    check_file_does_not_contain "Criptografía" "Inseguro BF-CBC ($node_name)" "$config" "BF-CBC|DES|3DES|RC4|MD5" \
        "Se detectó un cifrado vulnerable o débil (Blowfish/DES/RC4)!" \
        "Confirmado: Sin algoritmos obsoletos."

    # Privilege Drop
    check_file_contains "Control de Accesos" "Reducción Privilegios Usuario ($node_name)" "$config" "^user[[:space:]]+nobody" \
        "Falta drop de privilegios del proceso (user nobody)." \
        "Confirmado: drop de privilegios a 'nobody' configurado."

    check_file_contains "Control de Accesos" "Reducción Privilegios Grupo ($node_name)" "$config" "^group[[:space:]]+nobody" \
        "Falta drop de privilegios del proceso (group nobody)." \
        "Confirmado: drop de privilegios de grupo configurado."
done

# 2. Audit Client Profile Template
client_tmpl="docker/config/client.ovpn.template"
check_file_contains "Seguridad Cliente" "Cifrado GCM (Client)" "$client_tmpl" "^cipher[[:space:]]+AES-256-GCM" \
    "El cliente no exige cifrado AES-256-GCM." \
    "Confirmado: Cliente exige AES-256-GCM."

check_file_contains "Seguridad Cliente" "TLS Mínimo (Client)" "$client_tmpl" "^tls-version-min[[:space:]]+1.2" \
    "El cliente no exige TLS 1.2." \
    "Confirmado: Cliente exige TLS 1.2."

check_file_contains "Seguridad Cliente" "Protección MitM (Client)" "$client_tmpl" "^remote-cert-tls[[:space:]]+server" \
    "Falta validación remote-cert-tls server en el perfil de cliente." \
    "Confirmado: remote-cert-tls server activado para evitar MitM."

# 3. Check Subnet Segregation
subnet1=$(grep -oE "server [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" docker/config/server-node1.conf | awk '{print $2}' || echo "")
subnet2=$(grep -oE "server [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" docker/config/server-node2.conf | awk '{print $2}' || echo "")
if [ -n "$subnet1" ] && [ -n "$subnet2" ] && [ "$subnet1" != "$subnet2" ]; then
    add_check_result "Redes" "Segregación de Subredes" "PASSED" "Nodos segregados correctamente: Node 1 ($subnet1) vs Node 2 ($subnet2)"
else
    add_check_result "Redes" "Segregación de Subredes" "FAILED" "Las subredes colisionan o no están bien definidas: Node 1 ($subnet1) vs Node 2 ($subnet2)"
fi

# 4. Audit Docker Compose
compose_file="docker-compose.yml"
if [ -f "$compose_file" ]; then
    # Privileged flag block
    check_file_does_not_contain "Hardening Contenedor" "Sin Privilegios" "$compose_file" "privileged:[[:space:]]*true" \
        "El contenedor corre con privilegios máximos (privileged: true)!" \
        "Confirmado: Los contenedores no corren en modo --privileged."

    # Capabilities checks
    check_file_contains "Hardening Contenedor" "Drop Capabilidades" "$compose_file" "cap_drop:[[:space:]]*" \
        "Falta drop de capabilidades por defecto." \
        "Confirmado: Capabilidades por defecto eliminadas."

    check_file_contains "Hardening Contenedor" "Drop Capabilidades ALL" "$compose_file" "-[[:space:]]*ALL" \
        "No se eliminaron todas las capabilidades (cap_drop: ALL)." \
        "Confirmado: Se eliminaron todas las capabilidades por defecto."

    check_file_contains "Hardening Contenedor" "Add NET_ADMIN" "$compose_file" "-[[:space:]]*NET_ADMIN" \
        "Falta capabilidad NET_ADMIN necesaria para la interfaz TUN." \
        "Confirmado: NET_ADMIN añadido para el túnel."

    # Read-Only check
    check_file_contains "Hardening Contenedor" "FileSystem de Solo Lectura" "$compose_file" "read_only:[[:space:]]*true" \
        "Los contenedores no tienen el filesystem de sólo lectura." \
        "Confirmado: filesystem montado como read_only."
else
    add_check_result "Hardening Contenedor" "Docker Compose Audit" "FAILED" "Archivo docker-compose.yml no encontrado para auditoría."
fi

# Calculate stats
TOTAL_CHECKS=${#RULES[@]}
PASSED_CHECKS=0
for status in "${STATUSES[@]}"; do
    if [ "$status" == "PASSED" ]; then
        ((PASSED_CHECKS++))
    fi
done
SCORE=$(( (PASSED_CHECKS * 100) / TOTAL_CHECKS ))

# Define Status Color for UI
if [ "$SCORE" -eq 100 ]; then
    SCORE_COLOR="#10b981" # Green
    SCORE_LABEL="EXCELENTE"
elif [ "$SCORE" -ge 80 ]; then
    SCORE_COLOR="#3b82f6" # Blue
    SCORE_LABEL="SEGURO"
else
    SCORE_COLOR="#ef4444" # Red
    SCORE_LABEL="VULNERABLE"
fi

# ==========================================
# Generate Markdown Report (for Github Summary)
# ==========================================
echo "### 🛡️ Policy as Code (PaC) Audit Report" > "$MD_FILE"
echo "" >> "$MD_FILE"
echo "**Compliance Score: $SCORE% ($SCORE_LABEL)**" >> "$MD_FILE"
echo "Checks Passed: $PASSED_CHECKS / $TOTAL_CHECKS" >> "$MD_FILE"
echo "" >> "$MD_FILE"
echo "| Categoría | Regla Evaluada | Estado | Detalles / Mensaje |" >> "$MD_FILE"
echo "| --- | --- | --- | --- |" >> "$MD_FILE"

for ((i=0; i<TOTAL_CHECKS; i++)); do
    icon="✅ PASSED"
    if [ "${STATUSES[i]}" == "FAILED" ]; then
        icon="❌ FAILED"
    fi
    echo "| ${CATEGORIES[i]} | ${RULES[i]} | $icon | ${DETAILS[i]} |" >> "$MD_FILE"
done

# If running in GitHub Actions, append to GITHUB_STEP_SUMMARY
if [ -n "$GITHUB_STEP_SUMMARY" ]; then
    cat "$MD_FILE" >> "$GITHUB_STEP_SUMMARY"
fi

# ==========================================
# Generate Premium Glassmorphic HTML Report
# ==========================================
cat <<EOF > "$HTML_FILE"
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Policy as Code (PaC) Compliance Dashboard</title>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;800&family=JetBrains+Mono&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-gradient: linear-gradient(135deg, #090d16 0%, #111827 100%);
            --panel-bg: rgba(17, 24, 39, 0.65);
            --border-glow: rgba(255, 255, 255, 0.08);
            --text-primary: #f3f4f6;
            --text-secondary: #9ca3af;
            --accent-green: #10b981;
            --accent-green-glow: rgba(16, 185, 129, 0.15);
            --accent-red: #ef4444;
            --accent-red-glow: rgba(239, 68, 68, 0.15);
            --accent-blue: #3b82f6;
            --accent-violet: #8b5cf6;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: 'Outfit', sans-serif;
            background: var(--bg-gradient);
            color: var(--text-primary);
            min-height: 100vh;
            padding: 3rem 1.5rem;
            display: flex;
            justify-content: center;
            align-items: flex-start;
        }

        .dashboard-container {
            width: 100%;
            max-width: 1100px;
            background: var(--panel-bg);
            border: 1px solid var(--border-glow);
            border-radius: 24px;
            backdrop-filter: blur(20px);
            -webkit-backdrop-filter: blur(20px);
            padding: 2.5rem;
            box-shadow: 0 20px 50px rgba(0, 0, 0, 0.3), inset 0 1px 0 rgba(255, 255, 255, 0.1);
            animation: fadeIn 0.8s ease-out;
        }

        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(15px); }
            to { opacity: 1; transform: translateY(0); }
        }

        /* Header Section */
        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 2.5rem;
            border-bottom: 1px solid rgba(255, 255, 255, 0.05);
            padding-bottom: 1.5rem;
        }

        h1 {
            font-size: 2.2rem;
            font-weight: 800;
            background: linear-gradient(90deg, #fff 0%, #a78bfa 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .subtitle {
            font-size: 0.95rem;
            color: var(--text-secondary);
            margin-top: 0.3rem;
            font-weight: 300;
        }

        /* Stats Grid */
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1.5rem;
            margin-bottom: 3rem;
        }

        .stat-card {
            background: rgba(255, 255, 255, 0.02);
            border: 1px solid rgba(255, 255, 255, 0.04);
            border-radius: 16px;
            padding: 1.5rem;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            text-align: center;
            transition: all 0.3s ease;
        }

        .stat-card:hover {
            border-color: rgba(255, 255, 255, 0.1);
            background: rgba(255, 255, 255, 0.04);
            transform: translateY(-2px);
        }

        .stat-label {
            font-size: 0.85rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--text-secondary);
            margin-bottom: 0.5rem;
        }

        .stat-value {
            font-size: 2.5rem;
            font-weight: 800;
            color: #fff;
        }

        .score-gauge {
            font-size: 3rem;
            font-weight: 800;
            color: $SCORE_COLOR;
            text-shadow: 0 0 20px rgba(16, 185, 129, 0.2);
        }

        .badge-status {
            padding: 0.25rem 0.75rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
            margin-top: 0.4rem;
        }

        .status-excellent {
            background: var(--accent-green-glow);
            color: var(--accent-green);
            border: 1px solid rgba(16, 185, 129, 0.3);
        }

        .status-vulnerable {
            background: var(--accent-red-glow);
            color: var(--accent-red);
            border: 1px solid rgba(239, 68, 68, 0.3);
        }

        /* Rules Table */
        .table-wrapper {
            width: 100%;
            overflow-x: auto;
            border-radius: 14px;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }

        table {
            width: 100%;
            border-collapse: collapse;
            text-align: left;
            font-size: 0.95rem;
        }

        th {
            background: rgba(255, 255, 255, 0.02);
            font-weight: 600;
            color: #fff;
            padding: 1rem 1.25rem;
            border-bottom: 1px solid rgba(255, 255, 255, 0.05);
        }

        td {
            padding: 1.1rem 1.25rem;
            border-bottom: 1px solid rgba(255, 255, 255, 0.03);
            color: var(--text-primary);
        }

        tr:hover td {
            background: rgba(255, 255, 255, 0.01);
        }

        .rule-badge {
            display: inline-flex;
            align-items: center;
            padding: 0.25rem 0.6rem;
            border-radius: 6px;
            font-size: 0.75rem;
            font-weight: 500;
            font-family: 'JetBrains Mono', monospace;
            background: rgba(255, 255, 255, 0.04);
            color: var(--text-secondary);
        }

        .status-pill {
            display: inline-flex;
            align-items: center;
            gap: 0.35rem;
            font-size: 0.8rem;
            font-weight: 600;
            padding: 0.2rem 0.6rem;
            border-radius: 6px;
        }

        .pill-passed {
            background: var(--accent-green-glow);
            color: var(--accent-green);
        }

        .pill-failed {
            background: var(--accent-red-glow);
            color: var(--accent-red);
        }

        .detail-text {
            color: var(--text-secondary);
            font-size: 0.9rem;
            line-height: 1.4;
        }

        footer {
            margin-top: 3rem;
            text-align: center;
            font-size: 0.8rem;
            color: var(--text-secondary);
            border-top: 1px solid rgba(255, 255, 255, 0.03);
            padding-top: 1.5rem;
        }

        .footer-glow {
            display: inline-block;
            padding: 0.2rem 0.8rem;
            background: rgba(139, 92, 246, 0.05);
            border: 1px solid rgba(139, 92, 246, 0.1);
            color: #c084fc;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-family: 'JetBrains Mono', monospace;
        }
    </style>
</head>
<body>
    <div class="dashboard-container">
        <header>
            <div>
                <h1>Compliance Security Audit</h1>
                <div class="subtitle">Policy as Code (PaC) report for Hardened Active-Active OpenVPN</div>
            </div>
            <div class="footer-glow">CI/CD PIPELINE RUN</div>
        </header>

        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">Security Score</div>
                <div class="stat-value score-gauge" style="color: $SCORE_COLOR">$SCORE%</div>
                <div class="badge-status $([ "$SCORE" -eq 100 ] && echo "status-excellent" || echo "status-vulnerable")">$SCORE_LABEL</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Total Checks</div>
                <div class="stat-value">$TOTAL_CHECKS</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Checks Passed</div>
                <div class="stat-value" style="color: var(--accent-green)">$PASSED_CHECKS</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Checks Failed</div>
                <div class="stat-value" style="color: $([ "$FAILED" -eq 0 ] && echo "var(--text-secondary)" || echo "var(--accent-red)")">$((TOTAL_CHECKS - PASSED_CHECKS))</div>
            </div>
        </div>

        <div class="table-wrapper">
            <table>
                <thead>
                    <tr>
                        <th style="width: 20%;">Categoría</th>
                        <th style="width: 25%;">Regla Evaluada</th>
                        <th style="width: 15%;">Estado</th>
                        <th style="width: 40%;">Mensaje de Cumplimiento</th>
                    </tr>
                </thead>
                <tbody>
EOF

for ((i=0; i<TOTAL_CHECKS; i++)); do
    pill_class="pill-passed"
    pill_text="PASSED"
    dot="●"
    if [ "${STATUSES[i]}" == "FAILED" ]; then
        pill_class="pill-failed"
        pill_text="FAILED"
    fi
    
    cat <<EOF >> "$HTML_FILE"
                    <tr>
                        <td><span class="rule-badge">${CATEGORIES[i]}</span></td>
                        <td style="font-weight: 600;">${RULES[i]}</td>
                        <td>
                            <span class="status-pill ${pill_class}">
                                ${dot} ${pill_text}
                            </span>
                        </td>
                        <td class="detail-text">${DETAILS[i]}</td>
                    </tr>
EOF
done

cat <<EOF >> "$HTML_FILE"
                </tbody>
            </table>
        </div>

        <footer>
            <p>Generated automatically by DevSecOps pipeline on $(date)</p>
        </footer>
    </div>
</body>
</html>
EOF

echo "=== [PASSED] Generated compliance summaries and HTML dashboard! ==="
rm -f "$MD_FILE"

# Exit with pipeline exit code
if [ $FAILED -ne 0 ]; then
    echo "=== [FAILED] Audit found policy violations! ==="
    exit 1
else
    echo "=== [PASSED] All audits passed! ==="
    exit 0
fi
