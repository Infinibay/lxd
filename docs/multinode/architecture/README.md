# Infinibay Multi-Node — Especificación de Arquitectura (nivel datacenter)

Diseño enterprise generado y endurecido vía revisión adversarial multi-agente (26 agentes). Construye sobre el [reporte de estado](../01-current-state-report.md) y el [plan por fases](../02-implementation-plan.md).

## Documentos

- **[00 — Architecture Overview](./00-architecture-overview.md)** — documento integrador autoritativo: principios, topología, mapa de componentes, flujos de datos, modelo de consistencia, índice de ADRs, glosario.
- [01 — Plano de control & Node Agent](./01-control-plane.md)
- [02 — Modelo de datos, consistencia & pipeline de comandos](./02-data-model.md)
- [03 — Onboarding de nodos, descubrimiento & PKI](./03-onboarding-pki.md)
- [04 — Scheduling & placement de VMs](./04-scheduling.md)
- [05 — Migración de VMs — frío & caliente](./05-migration.md)
- [06 — Arquitectura de almacenamiento](./06-storage.md)
- [07 — Red de cluster & consola](./07-networking.md)
- [08 — Seguridad, RBAC & multi-tenancy](./08-security-rbac.md)
- [09 — Observabilidad, fallos & day-2 ops](./09-observability-ops.md)
- [10 — Despliegue, instalador & ciclo de vida del cluster](./10-deployment-installer.md)
- **[99 — Anexo: revisión adversarial](./99-review-findings.md)** — 48 hallazgos (10 blocker, 25 high) incorporados al diseño.

## Verificación de citas (2026-06-29)

Las afirmaciones de **estado actual** (citas `archivo:línea` sobre el código existente) fueron verificadas de forma independiente contra el código real por tres revisiones paralelas (control-plane+data-model, migración+networking, seguridad+instalador). Veredicto: **altamente preciso** — todas las proposals nuevas (`CommandOutbox`, `NodeCommand`, `epoch`, `RpcDatabaseAdapter`, `MigrationJob`…) correctamente marcadas como inexistentes hoy. Correcciones aplicadas: (1) `security.nesting` está en `envs/infinibay.yml:83`, no en el profile (afecta 10 + el reporte 01); (2) el default `-cpu host` está en `VMLifecycle.ts:437` (05); (3) `crons/all.ts:17`→`:18` (01-control-plane); (4) `graphicHost` no tiene "single producer", aparece en 5 sitios (07). Nota sustantiva añadida: **§6.2 del overview** formaliza el desacople DB de infinization (no Prisma en nodos vía `RpcDatabaseAdapter`, + follow-up recomendado de invertir el puerto).
