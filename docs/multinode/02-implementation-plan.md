# Infinibay Multi-Nodo — Plan de Implementación

> Basado en [`01-current-state-report.md`](./01-current-state-report.md). Resuelve los gaps **G0–G8** y
> reutiliza el andamiaje existente (`Node`, `Machine.nodeId`, `NodePlacementService`,
> `VMMigrationService` + `VMStorageMigrationAdapter`, API/UI de nodos).
>
> Objetivos del usuario:
> 1. Que el repo `lxd` instale **tanto el nodo maestro como las réplicas**, de forma muy simple.
> 2. **Auto-detección** del maestro en la red local + **doble verificación** de unión (algo en el
>    maestro y algo en el nodo nuevo, para que ambas partes acepten).
> 3. Tras crear un nodo: **mover VMs (en frío y en caliente)**, **saber dónde están**, y **ver el estado
>    de cada nodo**.

---

## 1. Decisión de arquitectura

### 1.1 Plano de control centralizado + Node Agents (recomendado)

```
                 ┌─────────────────────────── MASTER (control plane) ───────────────────────────┐
                 │  Postgres (única DB)   Backend/GraphQL (coordinador)   Frontend   CA mTLS     │
                 └───────────────┬───────────────────────┬───────────────────────────┬──────────┘
                                 │ mTLS RPC               │ mTLS RPC                   │ mTLS RPC
                        ┌────────▼────────┐      ┌────────▼────────┐         ┌────────▼────────┐
                        │  Node Agent     │      │  Node Agent     │   ...   │  Node Agent     │
                        │  (master-local) │      │  (compute-1)    │         │  (compute-N)    │
                        │  infinization   │      │  infinization   │         │  infinization   │
                        │  QEMU/KVM local │      │  QEMU/KVM local │         │  QEMU/KVM local │
                        └─────────────────┘      └─────────────────┘         └─────────────────┘
```

- **Una sola DB** (Postgres) en el maestro. Es el control plane y la fuente de verdad. Los nodos de
  cómputo **no tienen DB propia**: son ejecutores dirigidos por el maestro + reconciliación local de
  `/proc` *scoped a su `nodeId`*. Esto evita el infierno multi-master y responde la duda "¿cómo funciona
  la DB multi-nodo?" → **la DB no se distribuye; se centraliza, y los nodos son agentes sin estado
  persistente.** (HA de la DB = réplica Postgres, opcional, Fase 5.)
- **Node Agent**: daemon nuevo que corre en **cada** host hipervisor (incluido el del maestro). Posee la
  instancia local de `infinization`, lanza QEMU localmente, y expone una **RPC sobre mTLS** al backend.
- El **backend pasa de ejecutor a coordinador**: para cualquier operación de VM, resuelve
  `Machine.nodeId` → Node Agent dueño → RPC. En el host del maestro, el agente es localhost (fast-path).

#### ¿Por qué Node Agent y no "muchos backends compartiendo la DB"?
Un backend-por-nodo compartiendo Postgres choca de frente con **G0** (el reaper de huérfanos mataría las
VMs de otros nodos), duplica la API y multiplica la superficie de auth. El modelo agente concentra el
estado y la autoridad en el maestro, y mantiene `infinization` haciendo exactamente lo que ya hace bien:
gestionar QEMU **local**. El agente es "infinization + un transporte autenticado".

#### El Node Agent encapsula infinization
Hoy `infinization` corre in-process en el backend. El agente reutiliza la **misma librería** sin
reescribirla: el agente *es* el proceso que la hostea. El backend deja de importar `infinization`
directamente para operaciones de VM y pasa a hablar con agentes (en el maestro, contra su agente local).

### 1.2 Camino incremental (de-risking)
Para no bloquear todo detrás del agente, Fase 1 permite un **modo híbrido**: el backend sigue usando
`infinization` in-process para el **nodo local**, e introduce un `RemoteNodeClient` (mismo contrato que
`InfinizationService`) **solo para nodos remotos**. El despacho elige local-in-process vs agente-remoto
según `Machine.nodeId === localNodeId`. El "agente-en-todos-lados" (incluido el maestro) es el norte;
el híbrido es el primer hito entregable.

---

## 2. Cambios de modelo de datos (resuelve G1, G3)

Extender `Node` y añadir estado de unión/migración. (Free-form donde el schema ya lo permite; migración
Prisma donde se agregan columnas/modelos.)

```prisma
model Node {
  // --- existentes ---
  id, name, currentRaid, nextRaid?, cpuFlags Json, ram Int, cores Int,
  maintenanceMode Boolean @default(false), createdAt, updatedAt, disks Disk[], machines Machine[]

  // --- NUEVOS ---
  role            String   @default("compute")   // "master" | "compute"
  status          String   @default("pending")   // "pending" | "approved" | "online" | "offline" | "rejected" | "decommissioned"
  address         String?                         // IP/host alcanzable del agente (LAN)
  agentPort       Int      @default(9443)
  fingerprint     String?  @unique                // SHA-256 del cert cliente del agente (TOFU pin)
  certPem         String?                         // cert cliente firmado por la CA del maestro
  joinCodeHash    String?                         // hash del código de pairing (corto, efímero)
  joinNonce       String?
  lastHeartbeat   DateTime?                       // refresca staleness (G3)
  agentVersion    String?
  labels          Json?                           // p.ej. {"gpu":true,"zone":"rack-a"} para placement
  @@index([status])
}

model Machine {
  // ... + reusar `status = 'moving'` ya contemplado ...
  migrationJobId  String?    // job activo de migración (opcional)
}

// Auditoría/observabilidad de migraciones (cold y live)
model MigrationJob {
  id            String   @id @default(uuid())
  machineId     String
  sourceNodeId  String?
  targetNodeId  String
  mode          String   // "cold-shared" | "cold-copy" | "live"
  phase         String   // "queued"|"preparing"|"copying"|"activating"|"completed"|"failed"|"rolled_back"
  progress      Int      @default(0)
  bytesTotal    BigInt?
  bytesDone     BigInt?
  error         String?
  createdAt     DateTime @default(now())
  updatedAt     DateTime @updatedAt
  @@index([machineId]); @@index([phase])
}
```

`calculateNodeCapacity`/`nodeHealth` (`NodeCapacity.ts`) deben pasar a derivar staleness de
**`lastHeartbeat`** en vez de `updatedAt` (arregla G3). `status='online'` requiere heartbeat reciente
**y** `status` aprobado.

---

## 3. El Node Agent (resuelve G2, G5)

### 3.1 Forma
Un servicio liviano. Recomendación: **reutilizar el runtime del backend en "modo agente"** (mismo repo,
flag `INFINIBAY_ROLE=agent`) para no duplicar build/deps de `infinization`; expone solo la RPC del
agente, sin GraphQL ni DB. (Alternativa: daemon Node independiente que importe `@infinibay/infinization`.)

### 3.2 Contrato RPC (mTLS, JSON-RPC o gRPC)
Cada método opera **solo** sobre VMs cuyo `nodeId` == el del propio agente (enforced server-side):

- **Ciclo de vida**: `createVM(spec)`, `start(id)`, `stop(id, mode)`, `reboot(id)`, `delete(id)`,
  `getStatus(id)`, `listManaged()` → reconciliación local scoped por nodo.
- **Consola/IO**: `getConsoleInfo(id)` (SPICE/VNC host+port+ticket), `attachDisk`/`detachDisk`,
  `resizeDisk`.
- **Métricas/heartbeat**: `heartbeat()` → CPU/RAM/disco libres, versión, lista de VMs vivas + estados.
- **Storage (seam de migración)**: `exportDisk(id, target)` / `importDisk(...)` con streaming + checksum.
- **Live-migration**:
  - destino: `prepareIncoming(spec)` → lanza QEMU con `-incoming tcp:0.0.0.0:PORT` (+ devuelve
    endpoint/secret), pre-crea TAP/bridge/firewall/disco-destino.
  - origen: `startLiveMigration(id, dest)` → QMP `migrate-set-parameters` + `migrate tcp:dest`, opcional
    `drive-mirror`/`blockdev-mirror` si storage no compartido; `queryMigrate` para progreso; `cont` en
    destino al completar; teardown en origen.

### 3.3 Cambios en infinization (G0, G5)
- **G0 (bloqueador, primero):** `findRunningVMs` y el orphan-reaper deben filtrar por **`nodeId` del host
  actual**. Introducir `Infinization({ nodeId })` y propagarlo a `PrismaAdapter.findRunningVMs({ nodeId })`
  y a `findMachineByInternalName` (que ignore VMs de otros nodos). **Sin esto, multi-nodo corrompe
  datos.** (Aplica también al backend-coordinador: su reconcile solo toca VMs del nodo local.)
- **G5 (live-migration):** añadir a `QMPClient` los comandos `migrate`, `migrate-set-parameters`,
  `migrate-set-capabilities`, `query-migrate`, `migrate_cancel`; y a `QemuCommandBuilder` el soporte
  `-incoming`. Verificación de compatibilidad de CPU usando `Node.cpuFlags` (ya existe) + mismo
  machine-type.

### 3.4 Transporte y auth (resuelve G8)
- **mTLS** con una **CA propia del maestro** (creada en `setup.sh` del maestro). El agente presenta su
  cert cliente firmado; el maestro presenta su cert servidor. Ambos lados **pinean el fingerprint** del
  otro (TOFU) — guardado en `Node.fingerprint` y en el config del agente.
- Encaja con el modelo de confianza que el proyecto ya usa (LXD usa trust por certificados) y es más
  limpio que el HMAC para un daemon. Se reutiliza el patrón mental de `INFINISERVICE_HMAC_MASTER_SECRET`
  (comandos firmados al guest) pero a nivel de canal.

---

## 4. Onboarding de nodos — descubrimiento + doble verificación (resuelve G6, ask principal)

Flujo estilo "pairing" (como emparejar Bluetooth/SSH): **ambas partes deben aceptar y un código corto se
verifica out-of-band**. Esto satisface "meter algo en el maestro y algo en el nodo nuevo para estar
seguro de que ambas partes acepten".

### 4.1 Descubrimiento automático del maestro en la LAN
- El **maestro anuncia** un servicio mDNS/avahi `_infinibay-master._tcp` (puerto del agente + fingerprint
  de la CA en TXT). Se levanta en el provisioning del maestro.
- El comando de unión en el nodo nuevo (`./run.sh join` o `setup.sh --role node`) hace **mDNS browse**,
  encuentra el maestro y muestra:
  `> Maestro encontrado: infinibay-master (192.168.1.50:9443). ¿Conectar a este nodo? [s/N]`
  (Fallback manual: `--master 192.168.1.50` si no hay mDNS / hay segmentación de red.)

### 4.2 Secuencia de pairing con doble verificación

```
NODO NUEVO                         MAESTRO (backend + UI)                ADMIN
   │                                     │                                │
   │ 1. genera keypair + CSR             │                                │
   │ 2. POST /join {csr, hwInfo, pubkeyFP}│                               │
   │────────────────────────────────────▶│                                │
   │                                     │ 3. crea Node(status="pending") │
   │                                     │    code = trunc(hash(masterCA_FP│
   │                                     │           + nodePubkeyFP + nonce))│
   │  ◀── 4. responde {pairingCode, masterCA_FP} ──                       │
   │                                     │                                │
   │ 5. IMPRIME en la terminal del nodo: │ 5'. UI Infrastructure ▸ "Nodos │
   │    "Código de verificación: 47 29 13"│     pendientes" muestra el     │
   │    "Maestro CA: ab:cd:… ¿Aceptás?"  │     mismo código 47 29 13      │
   │                                     │                                │ 6. el admin compara
   │                                     │                                │    AMBOS códigos y,
   │                                     │                                │    si coinciden,
   │                                     │ ◀── 7. approveNode(id) ─────────│    aprueba en la UI
   │                                     │ 8. firma el CSR con la CA,      │
   │  ◀── 9. {signedCert, masterServerFP} ─    status="approved"          │
   │ 10. el nodo confirma (s/N) que el   │                                │
   │     masterServerFP coincide ────────▶│ 11. status="online", pin FP   │
   │ 12. ambos pinean el FP del otro (TOFU) y abren el canal mTLS         │
```

- **Doble verificación = dos confirmaciones humanas + un código que solo coincide si ambos fingerprints
  son los reales:**
  1. **En el maestro (UI):** el admin aprueba el nodo pendiente *verificando que el código mostrado en la
     pantalla del nodo nuevo coincide* con el de la UI. Defiende contra un nodo impostor.
  2. **En el nodo nuevo (terminal):** el operador confirma que el fingerprint de la CA del maestro es el
     esperado antes de entregar control. Defiende contra un maestro impostor / MITM.
  - Un atacante MITM no puede hacer coincidir el código en ambos lados sin poseer **ambos** fingerprints
    reales → el cotejo manual cierra el ataque.
- Tras aprobar: el maestro firma el cert del nodo (mTLS), persiste `fingerprint`/`certPem`,
  `status="online"`; el nodo guarda su cert + el FP pineado del maestro. A partir de ahí el canal es mTLS
  mutuo y el nodo aparece en el inventario.
- Estados de `Node.status`: `pending → approved → online` (o `rejected`/`offline`/`decommissioned`).

### 4.3 API/GraphQL de onboarding
- Endpoint HTTP del agente→maestro: `POST /node/join` (sin auth de sesión; protegido por el cotejo de
  código + aprobación).
- GraphQL (maestro): `pendingNodes: [PendingNodeType]`, `approveNode(id, expectedCode)`,
  `rejectNode(id)`, `decommissionNode(id)`, `nodeJoinInfo` (para la UI). Reemplaza el stub `setupNode`.

---

## 5. Operación de VMs cross-node (resuelve "saber dónde están" + routing)

- **Saber dónde está**: ya existe (`Machine.nodeId`, columna "Node" en UI, tarjeta "Node placement").
  Solo se completa con el detalle de nodo en vivo (§7).
- **Routing**: introducir un `NodeDispatcher` en el backend: dado `machineId`, carga `nodeId`, resuelve
  el `RemoteNodeClient` (o el agente local) y enruta `create/start/stop/console/...`. `CreateMachineServiceV2`,
  `VMOperationsService`, `SnapshotServiceV2`, `QemuGuestAgentService` pasan a llamar al dispatcher en vez
  de a `infinization` directo.
- **Placement** (ya existe `NodePlacementService`): quitar la preferencia hard por local cuando haya
  varios nodos válidos; respetar `labels` (p.ej. GPU), capacidad y `status='online'`. La creación enruta
  al agente del nodo elegido.
- **Consola**: `getConsoleInfo` devuelve `host:port` del nodo real (no `127.0.0.1`); el frontend ya
  modela `graphicHost`. El display debe bindear en una interfaz de management del nodo + ticket (la
  hardening secure-by-default de infinization ya cubre el ticket SPICE).

---

## 6. Migración de VMs — frío y caliente (resuelve G4, G5)

### 6.1 En frío (VM detenida) — completa el seam existente
Implementar `VMStorageMigrationAdapter.prepareMachineStorage` (el seam ya cableado en
`VMMigrationService.ts:4-11,121-124`). Dos modos:

- **`cold-shared`** (storage compartido NFS/Ceph): no se copia nada; solo se valida que el destino monta
  el mismo storage, se reasigna `nodeId` y se relanza en el destino. Camino más simple; `INFINIBAY_SHARED_STORAGE`
  ya está contemplado.
- **`cold-copy`** (storage local): el adapter ordena `exportDisk` en origen → stream sobre el canal mTLS
  → `importDisk` en destino → verifica checksum → reasigna `nodeId` → relanza. `MigrationJob` registra
  progreso (`bytesDone/bytesTotal`). Rollback si falla (no borrar origen hasta confirmar destino).

La mutación `migrateMachineToNode` y la **UI de migración en frío ya existen** — solo dejan de tirar el
error de "storage not configured" cuando el adapter está enchufado.

### 6.2 En caliente (live, VM encendida) — net-new
Orquestación maestro-dirigida sobre los agentes:
1. **Pre-checks**: compatibilidad de CPU (`Node.cpuFlags` origen ⊇ destino), misma machine-type,
   capacidad destino, storage (compartido → sin block-mirror; local → `drive-mirror`).
2. `target.prepareIncoming` → QEMU destino con `-incoming`; pre-crea red/firewall/disco.
3. `source.startLiveMigration` → QMP `migrate tcp:dest` (+ `drive-mirror` si local); `Machine.status='moving'`.
4. Poll `query-migrate` → progreso en `MigrationJob`.
5. Al completar: `cont` en destino, reasignar `nodeId`, teardown en origen, `status='running'`.
6. Fallo → `migrate_cancel`, la VM sigue viva en origen, `MigrationJob='rolled_back'`.

Requiere los comandos QMP nuevos + `-incoming` en infinization (§3.3). Es el mayor esfuerzo; va al final.

---

## 7. Frontend (resuelve gaps del §4 del reporte)

La UI ya tiene inventario, columna de nodo y migración en frío. Falta:
- **"Nodos pendientes" + aprobación con cotejo de código** (Infrastructure ▸ nueva sección): lista de
  `pendingNodes`, modal que muestra el código y pide confirmar que coincide con la pantalla del nodo →
  `approveNode(id, code)` / `rejectNode`. Reemplaza el stub `setupNode`.
- **Detalle de nodo** con métricas en vivo (heartbeat, capacidad, VMs alojadas, versión de agente,
  `lastHeartbeat`, online/offline real).
- **Acción de live-migration** en el detalle de VM (junto a la cold existente), con barra de progreso del
  `MigrationJob` (vía subscription/polling).
- Tipar `nodeId` explícito en `BackendMachine`/codegen (limpieza).

---

## 8. Instalador `lxd` — instalar maestro o unir nodo (resuelve G7)

### 8.1 Roles de instalación
- **`setup.sh` / `./run.sh` (rol master, default)**: comportamiento actual (postgres + backend + frontend)
  **+** Node Agent local **+** CA mTLS **+** anuncio mDNS `_infinibay-master._tcp`.
- **`setup.sh --role node` / `./run.sh join [--master IP]`**: instala **solo** qemu/kvm + `infinization`
  + el Node Agent (sin postgres/frontend/backend-API). Corre el descubrimiento mDNS y el pairing (§4).
  Mucho más liviano y rápido.

### 8.2 lxd-compose
- Nuevo `envs/infinibay-node.yml` con **un** grupo parametrizable (`{{NODE_NAME}}`, `{{MASTER_ADDR}}`) y
  un profile `infinibay-node.yml` (passthrough `/dev/kvm`, `security.nesting`, mounts de datos, proxy del
  puerto del agente). El nodo NO necesita el bridge ni el storage del maestro.
- Para nodos en **otra máquina física**, `connection:` de lxd-compose deja de ser `local`: o bien el
  operador corre `setup.sh --role node` directamente en la máquina nueva (camino simple, recomendado), o
  se apunta lxd-compose a un endpoint LXD remoto (avanzado).

### 8.3 Provisioning del nodo
Nuevo `provisioning/node.sh`: instala Node/qemu/infinization, genera keypair+CSR, ejecuta el join,
instala el systemd unit `infinibay-node-agent`, y verifica `/dev/kvm`. Sin DB ni migraciones.

---

## 9. Seguridad (resuelve G8, transversal)

- **mTLS** maestro↔agente con CA propia; pinning de fingerprints (TOFU) a ambos lados.
- **Doble verificación humana** en el onboarding (§4.2) contra nodo/maestro impostor y MITM.
- Autoridad RPC server-side: cada agente solo actúa sobre VMs de **su** `nodeId`; el maestro autoriza por
  permisos (`node:admin`, `node:join`, `node:migrate` — extender el sistema de permisos existente).
- Rotación/revocación de certs de nodo; `decommissionNode` revoca y limpia.
- No exponer el display en `0.0.0.0`: bindear en interfaz de management + ticket (ya hardened en
  infinization).

---

## 10. Roadmap por fases

> Orden guiado por riesgo: **primero lo que evita corrupción de datos**, luego ejecución remota, luego el
> onboarding (ask principal), luego migración.

| Fase | Objetivo | Entregables clave | Resuelve |
|------|----------|-------------------|----------|
| **0 · Seguridad de datos** | Que multi-nodo sea *no destructivo* antes de existir | `Infinization({nodeId})`; `findRunningVMs`/reaper/reconcile scoped por nodo; heartbeat → `Node.lastHeartbeat`; staleness desde heartbeat; columnas nuevas de `Node` + `MigrationJob` | G0, G1, G3 |
| **1 · Node Agent + routing** | El maestro maneja VMs en un nodo remoto | Node Agent (modo agente del backend) + RPC mTLS; `NodeDispatcher`/`RemoteNodeClient`; despacho de create/start/stop/console; placement multi-nodo | G2 |
| **2 · Onboarding + instalador** | Unir un nodo en minutos, seguro | mDNS discover/advertise; pairing + doble verificación; CA + firma de certs; `approveNode`/`pendingNodes`; `setup.sh --role node` / `run.sh join`; `envs/infinibay-node.yml`; UI de nodos pendientes | G6, G7, G8 |
| **3 · Migración en frío** | Mover VMs detenidas entre nodos | `VMStorageMigrationAdapter` (shared + copy); `MigrationJob` con progreso; detalle de nodo en la UI (la UI de cold-migrate ya existe) | G4 |
| **4 · Migración en caliente** | Mover VMs encendidas sin downtime | QMP `migrate`/`-incoming`/`query-migrate` en infinization; orquestación live; check de CPU; UI de live-migrate + progreso | G5 |
| **5 · Hardening / HA** | Producción | Réplica Postgres (HA del control plane); integración storage compartido; observabilidad/métricas de cluster; revocación de certs; tests adversariales (al estilo de las auditorías del proyecto) | — |

**Hito mínimo usable:** al terminar **Fase 2**, un operador puede correr `./run.sh join` en una máquina
nueva, verla aparecer como "pendiente" en la UI, aprobarla con el cotejo de código, y el maestro ya
crea/arranca/para VMs en ese nodo y muestra su estado. **Fase 3** agrega mover-en-frío (la UI ya está);
**Fase 4** el mover-en-caliente.

---

## 11. Riesgos y decisiones abiertas

- **Storage es el cuello de botella de la migración.** "Mover en caliente sin downtime" es mucho más
  simple con **storage compartido** (NFS/Ceph): sin copia, solo reasignar y relanzar. Con storage local
  hay que copiar/block-mirror discos qcow2 grandes por la red. **Decisión a tomar:** ¿el producto exige
  storage compartido para migración, o se soporta `cold-copy`/`drive-mirror` sobre storage local? (El
  seam soporta ambos; afecta esfuerzo de Fases 3–4.)
- **El agente, ¿proceso del backend en "modo agente" o daemon aparte?** Recomendado: modo del backend
  (un solo build/deps de infinization). Decisión menor pero conviene fijarla en Fase 1.
- **Compatibilidad de CPU para live-migration**: `Node.cpuFlags` ya existe; definir política (exigir
  CPUs homogéneas, o usar un modelo de CPU "baseline" común). Afecta Fase 4.
- **Red de VMs cross-node**: las VMs en distintos hosts que deben verse en la misma L2/departamento
  requieren bridging cross-host (VXLAN u overlay) — fuera del núcleo de este plan, pero a considerar si
  los departamentos deben abarcar nodos.
- **G0 es bloqueante y barato**: hacerlo en Fase 0 *aunque todavía no haya segundo nodo*, porque el
  riesgo (cross-kill de VMs) es de pérdida de datos.
