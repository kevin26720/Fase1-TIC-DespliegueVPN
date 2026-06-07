# Documentación del Despliegue - Cluster OpenVPN Activo-Activo (Docker)

Esta guía detalla la arquitectura, las estrategias de endurecimiento (hardening), la resolución de problemas de enrutamiento y los pasos para el despliegue automático del cluster de OpenVPN en entornos de producción basados en Docker y Docker Compose.

---

## 1. Arquitectura del Sistema

El cluster está compuesto por tres contenedores interconectados mediante una red bridge privada en Docker (`172.20.0.0/24`):

```
                       [ Clientes VPN ]
                              │
                              ▼
                       [ HAProxy LB ] (Puerto 1194/TCP, IP: 172.20.0.10)
                              │
               ┌──────────────┴──────────────┐ (Sticky Sessions por IP de Origen)
               ▼                             ▼
       [ OpenVPN Nodo 1 ]            [ OpenVPN Nodo 2 ]
      (IP: 172.20.0.11)             (IP: 172.20.0.12)
    Subred: 10.8.1.0/24           Subred: 10.8.2.0/24
```

### Versión Mínima y DCO (Data Channel Offload)
- **Versión recomendada de OpenVPN:** `2.6+`
- **Razón:** A partir de OpenVPN 2.6, se incluye soporte nativo para **DCO (Data Channel Offload)**. DCO traslada el cifrado y manejo de paquetes de datos directamente al espacio del kernel del sistema operativo host (usando el módulo de kernel `ovpn-dco`). Esto reduce drásticamente el costo de conmutación de contexto, permitiendo que un número significativamente menor de nodos maneje un volumen de tráfico muy superior.
- *Nota sobre contenedores:* Para usar DCO dentro de contenedores, el host destino debe tener cargado el módulo de kernel `ovpn-dco`. Nuestras configuraciones son compatibles y se degradan elegantemente al espacio de usuario si el módulo no está disponible.

---

## 2. Hardening Aplicado (Seguridad por Diseño)

El despliegue implementa controles rigurosos a nivel de contenedor y a nivel de proceso OpenVPN:

1. **Imagen Base Mínima:** Usamos `alpine:3.19` en el [Dockerfile](docker/Dockerfile), eliminando herramientas de compilación y limpiando las cachés de paquetes inmediatamente para reducir la superficie de ataque.
2. **Sistema de Archivos Inmutable (`read-only`):** Los contenedores se ejecutan con su sistema de archivos raíz en modo de sólo lectura. Los directorios de ejecución y registros (`/run`, `/var/log/openvpn`) se mapean como volúmenes volátiles temporales (`tmpfs`).
3. **Mínimo Privilegio de Capabilidades:** Se eliminan todos los privilegios del contenedor por defecto (`--cap-drop=ALL`) y únicamente se añade la capabilidad `NET_ADMIN` necesaria para gestionar la interfaz virtual `tun`.
4. **Prevención de Escalada de Privilegios:** Se configura `no-new-privileges:true` para evitar que los procesos hijos obtengan privilegios superiores a los de su padre.
5. **Privilegios de Usuario no-Root en OpenVPN:** OpenVPN inicia como `root` en el contenedor para abrir el dispositivo `tun` y añadir las reglas de `iptables`. Inmediatamente después, las directivas `user nobody` y `group nobody` en las configuraciones reducen los privilegios de ejecución del demonio OpenVPN.
6. **Hardening Criptográfico:**
   - Cifrado AEAD simétrico: `AES-256-GCM` (cifrado + autenticación de integridad en un solo paso).
   - TLS mínimo versión `1.2`.
   - Cifrado del canal de control mediante `tls-crypt` para mitigar ataques DoS de handshake y evitar escaneo/fingerprinting de puertos.
   - Deshabilitado por completo Blowfish (`BF-CBC`) para evitar la vulnerabilidad SWEET32.

---

## 3. Solución al Enrutamiento de Retorno (SNAT)

### El Problema Crítico
Cuando un cliente VPN con IP `10.8.1.5` (conectado al Nodo 1) envía un paquete a un servidor de la red interna, el servidor interno recibe el paquete. Al responder, la IP destino es `10.8.1.5`. Sin reglas especiales, el gateway por defecto de la red interna no sabrá qué nodo del cluster tiene asignado el rango `10.8.1.0/24` (Nodo 1) o `10.8.2.0/24` (Nodo 2), lo que causa pérdida de paquetes.

### Soluciones de Producción
En entornos reales de infraestructura, existen tres formas de solucionar esto:
- **Método A - SNAT (Source NAT):** El nodo de OpenVPN traduce la IP del cliente a su propia IP LAN (por ejemplo, `172.20.0.11`). El servidor interno responde directamente al nodo, y éste se encarga de re-enrutar el tráfico al cliente. Es el método más simple de implementar y es el que usamos en nuestra simulación local.
- **Método B - BGP/OSPF dinámico:** Se despliega un demonio de enrutamiento dinámico (como FRRouting o Bird) en cada nodo VPN. Cada nodo anuncia sus subredes activas al router/switch central. Si un nodo cae, la ruta se retira del core automáticamente.
- **Método C - PBR (Policy-Based Routing):** Se configuran tablas de enrutamiento basadas en políticas en los routers de la red física para forzar que el tráfico destinado a `10.8.1.0/24` pase por la IP del Nodo 1 como gateway.

*Nuestra configuración local:* Dentro de [entrypoint.sh](docker/entrypoint.sh) aplicamos **SNAT** a nivel de contenedor con la siguiente regla:
```bash
iptables -t nat -A POSTROUTING -s 10.8.0.0/16 -o eth0 -j MASQUERADE
```
Esto permite que cualquier servidor en la red de Docker se comunique con los clientes de la VPN sin necesidad de configurar rutas adicionales en la red.

---

## 4. Persistencia de la CRL (Lista de Revocación de Certificados)

Para asegurar el cumplimiento del requerimiento de poder revocar accesos de inmediato en un entorno inmutable (`read-only`):
- Creamos un volumen Docker compartido llamado `openvpn_crl_share`.
- Este volumen se monta en la ruta `/etc/openvpn/crl` en ambos nodos servidores de OpenVPN en modo **sólo lectura** (`ro`).
- Cuando la autoridad certificadora (CA) revoca un certificado, genera un nuevo archivo `crl.pem`.
- Un script de administración (o nuestro script de despliegue) actualiza el archivo `crl.pem` dentro del volumen compartido.
- OpenVPN vuelve a leer la CRL automáticamente en cada conexión entrante, denegando el acceso a los certificados revocados de inmediato y sin requerir el reinicio de los contenedores.

---

## 5. Instrucciones de Ejecución Local (Paso a Paso)

### Paso 1: Inicializar la PKI de Prueba
Genera los certificados y claves necesarias de forma automática usando OpenSSL. Las claves privadas y certificados generados se ubicarán en `docker/config/pki/` (ruta excluida en `.gitignore` para no subir secretos al repositorio).
```bash
chmod +x scripts/init-pki.sh
./scripts/init-pki.sh
```

### Paso 2: Ejecutar el Linter de Cumplimiento de Políticas
Valida que ninguna configuración de OpenVPN o Docker Compose viole los estándares de seguridad requeridos (por ejemplo, detecta si se configuró `BF-CBC` por error o si se olvidó de inhabilitar privilegios root en Compose).
```bash
chmod +x tests/check-config.sh
./tests/check-config.sh
```

### Paso 3: Levantar el Entorno con Docker Compose
Inicia el balanceador HAProxy y los dos nodos OpenVPN.
```bash
docker-compose up --build -d
```

### Paso 4: Validar el Funcionamiento del Cluster
1. Revisa los logs para confirmar que el arranque no presenta errores:
   ```bash
   docker logs openvpn-node1
   docker logs openvpn-node2
   docker logs haproxy-lb
   ```
2. El balanceador HAProxy estará escuchando en el puerto local `1194/TCP`. Al conectar múltiples clientes, HAProxy los distribuirá a los nodos de manera persistente usando la IP de origen.

---

## 6. Automatización de GitHub Actions (CI/CD)

El archivo [.github/workflows/deploy-vpn.yml](.github/workflows/deploy-vpn.yml) automatiza el flujo de calidad y despliegue continuo:
1. **Linter de Dockerfile:** Valida buenas prácticas en el empaquetado mediante `Hadolint`.
2. **Policy as Code:** Ejecuta `./tests/check-config.sh` para auditar la configuración de seguridad.
3. **Escaneo de Imagen:** Construye la imagen y la escanea con `Trivy` en busca de vulnerabilidades críticas en el sistema operativo base Alpine.
4. **Despliegue Remoto:** Si las pruebas pasan y la rama es `main`, ejecuta el script `./scripts/deploy-target.sh`.

### Secretos requeridos en GitHub
Para habilitar el despliegue automático al servidor destino, debes configurar los siguientes secretos en los ajustes de tu repositorio de GitHub (`Settings > Secrets and variables > Actions`):

- `TARGET_HOST`: La dirección IP (puede ser la IP privada de Tailscale, ej: `100.x.y.z`) o nombre de dominio del servidor destino.
- `TARGET_USER`: El usuario SSH con el que se realizará la conexión (por ejemplo, `ubuntu`, `root` o tu usuario de Windows).
- `TARGET_SSH_KEY`: La clave privada SSH (completa) autorizada en el servidor destino.
- `TARGET_PORT` *(Opcional)*: El puerto SSH del servidor destino (por defecto es `22`).
- `TAILSCALE_AUTH_KEY` *(Opcional)*: Tu clave de autenticación de Tailscale (Auth Key o Ephemeral Key). Si se proporciona, el pipeline de GitHub Actions se conectará automáticamente a tu red privada (Tailnet) antes de realizar el despliegue por SSH, permitiendo conectarse de forma 100% segura a máquinas privadas sin exponerlas a Internet.
