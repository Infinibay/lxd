# Infinibay Multi-Nodo — Reporte de Estado Actual

> Fecha: 2026-06-29 · Alcance: repos `lxd` (instalador), `backend`, `infinization`, `frontend`.
> Método: exploración dirigida con evidencia `archivo:línea`. Documento de diagnóstico; el plan de
> implementación vive en [`02-implementation-plan.md`](./02-implementation-plan.md).

## TL;DR

El sistema está en un estado **medio-construido y asimétrico**: existe una **capa de *descripción*
multi-nodo** (modelo `Node` en la DB, API GraphQL de nodos, UI de Infrastructure y migración en frío)
pero **no existe la capa de *ejecución***. El plano de control corre **in-process dentro del backend**
y lanza QEMU como proceso hijo local; no hay forma de que el backend controle un hipervisor en otra
máquina. El instalador despliega una topología fija de 3 contenedores en **una sola máquina** con el
hipervisor embebido dentro del contenedor del backend.

**Veredicto por capa:**

| Capa | Estado | Resumen |
|------|--------|---------|
| Instalador (`lxd`) | 🔴 Single-host | Topología fija de 3 contenedores, hipervisor dentro del backend, sin rol master/node, sin descubrimiento. |
| DB / Schema | 🟡 Modela nodos, pero primitivo | Existe `Node` y `Machine.nodeId`, pero `Node` **no tiene dirección de red, token, fingerprint, rol ni heartbeat**. |
| Backend / API | 🟡 Andamiaje, no ejecución | `nodes`/`migrateMachineToNode`/placement existen, pero la migración solo reescribe `nodeId`; el control es local. |
| infinization | 🔴 Local puro | `child_process.spawn`, sockets Unix locales, sin migración, **reaper de huérfanos no scoped por nodo** (peligro de datos). |
| Frontend | 🟢 ~80% node-aware | Página Infrastructure, columna de nodo por-VM, tarjeta de migración en frío. Falta onboarding y live-migration. |

El "gap" no es "no hay nada"; es **"existe el describir-lo, falta el hacerlo"**, más un par de
**landmines de corrupción de datos** que deben arreglarse antes de cualquier multi-nodo real.

---

## 1. Instalador / Despliegue (repo `lxd`) — Single-host por diseño

### 1.1 Qué instala hoy
Dos caminos independientes: **LXD** (producción) y **Docker** (desarrollo, hot-reload). El de LXD es el
primario.

- `setup.sh` prepara el host: exige `/dev/kvm` (`setup.sh:43`), instala `qemu-kvm`/`bridge-utils`/etc.
  (`setup.sh:443`), instala LXD y lo preconfigura con **un** bridge `lxdbr0` y **un** storage pool `dir`,
  con `core.trust_password: infinibay` (`setup.sh:266-297`), y crea `/var/lib/infinibay/data/...`.
- `run.sh apply` → `lxd-compose apply infinibay` lee `envs/infinibay.yml` y crea **exactamente 3
  contenedores**: `infinibay-postgres`, `infinibay-backend`, `infinibay-frontend` (nombres hardcodeados
  en todo `run.sh`, p.ej. `run.sh:139`).
- `provisioning/provision-all.sh` aprovisiona en orden postgres → backend → frontend.
  **infiniservice NO se instala en ningún nodo** — es el agente *dentro* de cada VM invitada.

### 1.2 El hipervisor vive DENTRO del backend
Punto arquitectónico central: el contenedor del backend recibe passthrough de `/dev/kvm` y
`security.nesting: "true"` (el passthrough de KVM está en `profiles/templates/infinibay-backend.yml:9-12`; el flag `security.nesting` se setea en `envs/infinibay.yml:83`), instala `qemu-kvm`
(`backend.sh:25`) y construye los bindings nativos `libvirt-node` en `/opt/infinibay/libvirt-node`
(`run.sh:855-1046`). Es decir, **QEMU/KVM corre en el mismo contenedor (y misma máquina) que la API**.
No hay ninguna ruta para apuntar el backend a un libvirt/hipervisor en otra máquina.

> Nota: `libvirt-node` es **legacy**. `InfinizationService.ts:4` declara que ese servicio "replaces
> direct libvirt-node usage with the infinization library". El runtime real de VMs es **infinization
> in-process** (§3). `RPC_URL=http://localhost:9090` (`backend.sh:198`) es vestigial: solo aparece como
> variable requerida en un health-check (`VMHealthQueueManager.ts:79`), no se usa como seam de RPC.

### 1.3 Sin concepto master/worker ni descubrimiento
Búsqueda en todo el repo de `node|cluster|master|replica|worker|peer|join|hypervisor|remote host`: solo
aparecen Node.js, "nodes" de lxd-compose (= contenedores), el HMAC "master secret" y el override
"hypervisor" de Docker. **No hay** rol de nodo, `connection:` remoto de lxd-compose (todo es
`connection: "local"`, `envs/infinibay.yml:37,67,89`), mDNS/avahi, registro, ni direccionamiento
cross-host. El `DATABASE_URL` apunta a `infinibay-postgres:5432` por DNS interno de `lxdbr0`
(`backend.sh:174`) — solo resuelve en el mismo host LXD. `HOST_IP`/`APP_HOST` describen **la propia
máquina a sus clientes** (browser/VMs), nunca a un peer.

**Veredicto instalador:** topología single-host hardcodeada; el hipervisor está acoplado al backend.
Para N nodos faltaría: rol de instalación, seam de hipervisor remoto, registro/direccionamiento de
nodos, y `connection:` no-local de lxd-compose — nada de eso existe.

---

## 2. Backend — Andamiaje multi-nodo sin plano de ejecución

### 2.1 El modelo `Node` existe, pero es primitivo
`prisma/schema.prisma:185-198`:
```prisma
model Node {
  id, name, currentRaid, nextRaid?, cpuFlags Json, ram Int, cores Int,
  maintenanceMode Boolean @default(false), createdAt, updatedAt,
  disks Disk[], machines Machine[]
}
```
Modela hardware de un hipervisor (cpuFlags, ram, cores, RAID, discos, maintenance). **Pero le falta todo
lo necesario para ser un nodo remoto direccionable:** no hay `address`/`port`/`apiUrl`, ni `fingerprint`/
`certificate`/`joinToken`, ni `role` (master/compute), ni `status` (pending/online/offline), ni
`lastHeartbeat`, ni `agentVersion`. `Machine` está atado a un nodo vía `nodeId String?` (nullable),
`@@index([nodeId])` y la relación `onDelete: SetNull` (`schema.prisma:246,253,279`). `Machine` también
lleva `localIP`/`publicIP` (`:247-248`) y el estado `moving` está contemplado en el enum de status
(`:230`). La DB es **un único Postgres** — sin sharding/replicación/per-node.

### 2.2 La VM siempre se crea y corre localmente
- En creación, `machineLifecycleService.ts:95` llama a `NodePlacementService.chooseNodeForMachine(...)`
  y persiste el resultado en `Machine.nodeId` (`:110`). **Se elige y guarda un nodo.**
- Pero el placement **siempre prefiere el nodo local**: `NodePlacementService.ts:51,62,69` ordena por
  `isLocal: node.name === (INFINIBAY_NODE_NAME || os.hostname())`. Y en la práctica solo el nodo local
  llega a registrarse.
- El lanzamiento real: `InfinizationService.ts:115` construye `new Infinization({ ... diskDir,
  qmpSocketDir, pidfileDir ... })` — **solo directorios locales**, ningún parámetro host/IP/SSH.
- `LocalNodeRegistrationService` solo registra **la propia máquina del backend** como Node
  (`detectLocalHardware()` usa `os.hostname()` + `systeminformation`; `registerLocalNode()` upsert por
  hostname). Se invoca únicamente desde la mutación `setupNode`, que además es un **stub que devuelve
  `DyummyType`** (`graphql/resolvers/setup/resolver.ts:14,41`).

### 2.3 Superficie GraphQL de nodos (existe; ejecución no)
`app/graphql/resolvers/node/resolver.ts`:
- Queries: `nodes`, `node(id)`, `nodeInventorySummary` — exponen `health` (online/stale),
  `availableCores`, `availableRamGB`, `machineCount`, `runningMachineCount`, `maintenanceMode`, discos.
- Mutaciones: `setNodeMaintenanceMode(id, enabled)`, `setupNode` (stub), y
  `migrateMachineToNode(id, targetNodeId): MachineMigrationResultType`.
- Salud por staleness: `NodeCapacity.ts:27-30`, `NODE_STALE_AFTER_MS = 5 min`. **La salud se deriva de
  `Node.updatedAt`** — pero nada refresca `updatedAt` después del setup (no hay heartbeat), de modo que
  hoy *cualquier nodo se leería como `stale` a los 5 minutos*. ⚠️
- `moveMachine(id, departmentId)` es **otra cosa**: reasigna departamento + bridge + TAP + reglas de
  firewall (`VMMoveService.ts`), no mueve de host.

### 2.4 "Migración" entre nodos = reescribir una columna
`VMMigrationService.migrateStoppedMachineToNode` (`app/services/node/VMMigrationService.ts:35-113`):
- Solo VMs detenidas (`MIGRATABLE_STATUSES = {off, stopped, error}`, `:26,51`).
- Valida que el nodo destino exista, no esté en maintenance, no esté stale y tenga capacidad (`:64-93`).
- Llama a `prepareStorageForMigration` (`:115-131`) que **no copia nada**: si no hay storageAdapter
  inyectado y `INFINIBAY_SHARED_STORAGE` no está activo, **lanza error** "VM storage migration is not
  configured…" (`:128-130`).
- Si pasa, hace `prisma.machine.update({ data: { nodeId: targetNodeId } })` (`:102-105`). Nada más.

> ✅ El seam correcto **ya está diseñado**: `interface VMStorageMigrationAdapter` con
> `prepareMachineStorage({machineId, sourceNodeId, targetNodeId, diskPaths})` (`VMMigrationService.ts:4-11`).
> Es el punto exacto donde enchufar la copia/relocalización de discos en el plan.

### 2.5 Modelo de conexión al hipervisor
**Solo llamadas a librería in-process.** El backend importa `@infinibay/infinization` (symlink al fuente)
y maneja QEMU vía sockets Unix QMP locales, pidfiles locales e imágenes en `diskDir` local
(`InfinizationService.ts:118-120`). No hay libvirt-sobre-red, `qemu+ssh://`, RPC TCP, ni agente en host
remoto. ¿Podría un backend controlar QEMU en otra máquina hoy? **No** — bloqueado por: spawn local,
socket QMP local, discos en `diskDir` local, storage de migración no implementado, networking/nftables
aplicado por comandos locales, y `LocalNodeRegistrationService` que solo registra el propio host.

**Veredicto backend:** schema/API *node-aware* (puede **describir** un cluster), runtime **single-host**.
Las piezas (`Node`, `nodeId`, placement, migración-metadata, maintenance, staleness, el seam de storage)
son groundwork prospectivo: dejan describir un cluster, pero nada ejecuta ni migra una VM en un
hipervisor remoto.

---

## 3. infinization — Ejecutor 100% local, con un landmine de datos

### 3.1 Modelo de ejecución: solo local, sin seam remoto
Todo comando externo pasa por `CommandExecutor`, un wrapper fino sobre `child_process.spawn` **local**:
`utils/commandExecutor.ts:1,89`. QEMU se lanza igual: `core/QemuProcess.ts:207`
(`spawn(actualCommand, actualArgs, {detached:true,...})`). No existe SSH, `qemu+ssh`, ni parámetro
`host`/`hostname` en `CommandOptions`. QMP y guest-agent son **sockets Unix locales**
(`QMPClient.ts:83-85`, `GuestAgentClient.ts:73`; QMP siempre `unix:<path>,server,nowait`,
`QemuCommandBuilder.ts:397`).

### 3.2 Todo lo "dónde vive la VM" es implícitamente local
- **Discos**: paths locales bajo `/var/lib/infinization/disks/...` (`config.types.ts:26`); ROMs lockeados
  a `/var/lib/infinization/roms/` (`QemuCommandBuilder.ts:53`).
- **Bridges/TAP/nftables**: `BridgeManager`/`TapDeviceManager`/`NftablesService` ejecutan `ip`/`nft`
  locales sobre el kernel de este host.
- **cgroups/NUMA**: `/sys/fs/cgroup/infinization.slice` y `/sys/devices/system/node`
  (`CgroupsManager.ts:28,31`) — pseudo-FS del kernel local.
- **PID/liveness**: lee `/proc/<pid>/cmdline` y manda señales locales (`processIdentity.ts:38,131,203`;
  `HealthMonitor.ts:1020`). Un PID solo es interpretable en el host que lo posee — el binding local más
  fuerte.
- **Display**: defaults loopback `127.0.0.1` (`display.types.ts:36,39`). `graphicHost` = dónde QEMU
  *bindea* el display localmente, no en qué host físico corre la VM.

### 3.3 Sin migración de ningún tipo
`grep` de `migrate`/`-incoming`/`drive-mirror` en `src`: **sin coincidencias** reales. `QMPClient` expone
un set fijo (`queryStatus`, `powerdown`, `reset`, `stop`, `cont`, `quit`, `eject`, `queryCpus`,
`queryBlock`, `balloon`...) **sin `migrate`/`migrate-incoming`** (`QMPClient.ts:301-548`). QEMU nunca se
lanza con `-incoming`, así que una VM **ni siquiera puede arrancar como destino de migración**. Las
únicas referencias a "migration" son: (a) mapeo de estados QEMU (`inmigrate`/`postmigrate`) a estados de
DB en `StateSync.ts:22-40` — *observa* migración, no la inicia; y (b) `seamless-migration=on` del cliente
SPICE (reconexión del visor, no relocalización de la VM).

### 3.4 ⚠️ Landmine: el reaper de huérfanos NO está scoped por nodo
La DB es la fuente de verdad host-agnóstica. `PrismaAdapter.findRunningVMs()` filtra **solo por
`status='running'`** (`PrismaAdapter.ts:139-152`), no por host. El escáner de huérfanos
(`Infinization.ts`) mapea PIDs locales a registros de DB vía `findMachineByInternalName` y mata procesos
que no encuentra. **Si dos backends/agentes compartieran esta DB sin scoping por nodo, cada uno trataría
las VMs del otro como huérfanas y las mataría (SIGKILL, como root).** No existe ninguna columna
`hostId`/`nodeId` *consultada por infinization* (la lib no lee `Machine.nodeId`). Esto es un **bloqueador
de seguridad de datos** previo a cualquier multi-nodo.

**Veredicto infinization:** gestor QEMU single-host, in-process, sin node-awareness ni capacidad remota.
Multi-nodo exige: un seam de ejecución remota bajo `CommandExecutor`/`QemuProcess`, direccionamiento
host-cualificado de cada socket/path/interfaz, ownership de DB scoped por nodo, y plumbing de migración
totalmente nuevo.

---

## 4. Frontend — Sorpresivamente node-aware (~80%)

Contrario a lo esperado, la UI **ya tiene** superficie multi-nodo cableada:

- **Página Infrastructure** dedicada: `src/app/infrastructure/page.js` — `DataTable` de nodos (nombre +
  rol + `StatusDot`, CPU, memoria, storage, workload `running/total`, presión %, **toggle de
  maintenance**, último reporte) + medidores de capacidad del nodo local + tarjeta "Node inventory". Cae
  a una fila sintética "Local node" si no hay nodos registrados (`infrastructure/page.js:144-167`). En el
  nav: `AppSidebar.jsx:64` (sección System, ícono `Server`).
- **Placement por-VM visible**: columna "Node" en la lista (`DesktopListView.jsx:218-232`, resuelve
  `nodeId`→nombre vía `nodeNameById`), alimentada por `useGetNodeInventoryQuery` en
  `desktops/page.js:133` y `departments/[name]/page.js:114`.
- **Migración en frío YA existe**: tarjeta "Node placement" en el detalle de VM
  (`departments/[name]/desktops/[id]/page.js:417-457`) con `useMigrateMachineToNodeMutation`,
  selección de nodo destino (excluye maintenance), guard cold-only (`canColdMigrateStatus`, `:124-126`),
  y caption "Cold migration requires shared VM storage across nodes".
- **Maintenance por nodo**: `SetNodeMaintenanceMode`.

**Gaps reales del frontend:**
- **No hay UI de alta/onboarding/aprobación de nodos.** `setupNode` está codegen'd (`useSetupNodeMutation`)
  pero **nunca se importa ni llama**; devuelve `DyummyType { value }`.
- Migración **solo en frío** (sin live-migration UI).
- Tipado débil: `BackendMachine` (`adapters.ts:15`) y el `MachineType` generado no declaran `nodeId`
  explícito (viaja por el index-signature + la selección de la query) — debilidad de tipos, no funcional.

**Veredicto frontend:** node-aware al ~80%. Falta esencialmente el **flujo de onboarding/aprobación**, el
**detalle de nodo con métricas en vivo**, y la **live-migration**.

---

## 5. Síntesis — Gaps consolidados (insumo del plan)

| ID | Gap | Capa | Severidad |
|----|-----|------|-----------|
| **G0** | Reaper de huérfanos / `findRunningVMs` no scoped por nodo → cross-kill de VMs entre nodos | infinization | 🔴 Bloqueador de datos |
| **G1** | `Node` sin dirección/puerto/fingerprint/token/rol/status/heartbeat → no es direccionable | DB | 🔴 |
| **G2** | Plano de control in-process; no hay ejecución remota (sin agente/RPC/SSH) | backend+infinization | 🔴 |
| **G3** | Staleness derivada de `updatedAt` pero **nada hace heartbeat** | backend | 🟠 |
| **G4** | Migración es metadata-only; copia de storage no implementada (seam vacío) | backend | 🟠 |
| **G5** | Sin primitivas de live-migration (`-incoming`, QMP `migrate`, block-mirror) | infinization | 🟠 |
| **G6** | Sin descubrimiento/onboarding/aprobación; `setupNode` es stub | full-stack | 🟠 (ask principal) |
| **G7** | Instalador single-host fijo; hipervisor embebido en backend; sin rol node | instalador | 🔴 |
| **G8** | Sin auth nodo↔master (sin CA/mTLS); solo trust-password de LXD | seguridad | 🔴 |

**Lo que YA juega a favor** (no hay que inventarlo): modelo `Node` + `Machine.nodeId` + índice;
`NodePlacementService` con scoring por capacidad; `VMMigrationService` con guards + **el seam
`VMStorageMigrationAdapter`**; `NodeCapacity`/staleness; API GraphQL de nodos; y casi toda la UI de
inventario y migración en frío. El campo `Node.cpuFlags` incluso anticipa la verificación de
compatibilidad de CPU que exige la live-migration.

El plan en [`02-implementation-plan.md`](./02-implementation-plan.md) parte de estos gaps y reutiliza
agresivamente el andamiaje existente.
