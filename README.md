# DeliveryHero Platform Integration

This repository runs the local end-to-end environment for the two services:

- `global-food-catalog-platform`: Catalog Command Service and transactional outbox
- `effective-menu-service`: Kafka consumer, effective-menu read model, and customer API

## Expected folder layout

```text
Java-Backend/
├── global-food-catalog-platform/
├── effective-menu-service/
└── deliveryhero-platform-integration/
```

## Start the complete stack

From this repository:

```powershell
docker compose up --build
```

The stack exposes:

| Component | Address |
|---|---|
| Catalog API | http://localhost:8080 |
| Effective Menu API | http://localhost:8081 |
| Catalog PostgreSQL | localhost:5435 |
| Effective Menu PostgreSQL | localhost:5434 |
| Kafka | localhost:9092 |

Health checks:

```powershell
Invoke-RestMethod http://localhost:8080/actuator/health
Invoke-RestMethod http://localhost:8081/actuator/health
```

Detailed readiness checks:

```powershell
curl.exe -s http://localhost:8080/actuator/health/liveness
curl.exe -s http://localhost:8080/actuator/health/readiness
curl.exe -s http://localhost:8081/actuator/health/liveness
curl.exe -s http://localhost:8081/actuator/health/readiness
curl.exe -s http://localhost:8081/actuator/effective-menu
```

Catalog and Effective Menu readiness depends on PostgreSQL and Kafka. Liveness remains
`UP` while the process is running. Redis is optional: stopping it must not fail the
customer menu API because Effective Menu falls back to PostgreSQL.

Failure-recovery checks:

```powershell
docker compose stop kafka
docker compose start kafka
docker compose stop redis
docker compose start redis
docker compose stop effective-menu-postgres
docker compose start effective-menu-postgres
docker compose ps
```

The service images must be rebuilt after Java or property changes:

```powershell
docker compose up -d --build catalog-service effective-menu-service
```

Run the real reconciliation smoke test after the stack is healthy:

```powershell
.\scripts\reconciliation-smoke-test.ps1
```

The script creates unique test data, verifies `MISSING_SNAPSHOT`, creates a matching
read-model snapshot, and verifies `MATCH` through the Catalog reconciliation API.

Stop the stack:

```powershell
docker compose down
```

The Compose stack is for local integration only. Testcontainers remains responsible for automated integration tests.

Failure and recovery procedures are documented in [FAILURE_RECOVERY.md](FAILURE_RECOVERY.md).

GitHub Actions uses `docker-compose.ci.yml` because the workflow checks out both service
repositories inside the integration workspace. Local development continues to use the
standard `docker-compose.yml` file and its sibling-directory build contexts.

### Scheduled-availability verification

After the stack is healthy, create or update a schedule through the Catalog API and
inspect the newest outbox row. After it becomes `PUBLISHED`, read the same outlet from
the Effective Menu API. The item remains visible while `availability` follows the
outlet-local current time, and only that outlet's Redis key is evicted.

```powershell
docker compose exec -T catalog-postgres psql -U catalog_app -d catalog_command_db `
  -c "SELECT id, status, aggregate_id, aggregate_version FROM outbox_event ORDER BY id DESC LIMIT 5;"
curl.exe -s http://localhost:8081/api/v1/outlets/{outletId}/menu
docker compose exec redis redis-cli keys "effective-menu:*"
```

The focused automated proof is
`MenuItemChangedEventApiEndToEndIntegrationTest.scheduleChange_updatesAvailabilityAndCustomerApiResponse`.

### Release 1.1 seasonal availability

Seasonal date-range changes follow the same safe path as weekly schedules:
Catalog PostgreSQL and its outbox commit together, Kafka delivers the versioned event,
Effective Menu updates its PostgreSQL read model, evicts Redis, and evaluates the
outlet-local seasonal range on customer reads. Ranges are start-inclusive and end-exclusive.

### Release 1.1 bundle verification

Bundle configuration changes travel through the same transactional path: Catalog
PostgreSQL → outbox → Kafka → Effective Menu PostgreSQL → Redis eviction → customer
API. The customer response exposes `bundleChildren` as ordered ID/name/quantity
summaries. An unavailable required child leaves its parent bundle visible but sold out;
a hidden, draft, or archived child removes the parent bundle from the customer menu.

The Catalog endpoint is a complete replacement API. A newly created bundle starts
as `DRAFT`; configure it first and activate it only after the composition request
returns. This gives Effective Menu a complete tree before customers can see it.

```powershell
$chainId = 1
$outletId = 1
$childOneId = 10
$childTwoId = 11

$bundle = Invoke-RestMethod `
  -Method Post `
  -ContentType "application/json" `
  -Uri "http://localhost:8080/api/v1/restaurant-chains/$chainId/outlets/$outletId/menu-items" `
  -Body (@{
    businessCode = "BURGER-MEAL-DEMO"
    itemName = "Burger Meal"
    itemPrice = 299
    menuItemKind = "BUNDLE"
  } | ConvertTo-Json)

$bundleId = $bundle.id

$body = @{
  expectedVersion = $bundle.version
  children = @(
    @{ childMenuItemId = $childOneId; quantity = 1; displayOrder = 0 }
    @{ childMenuItemId = $childTwoId; quantity = 1; displayOrder = 1 }
  )
} | ConvertTo-Json -Depth 4

$composition = Invoke-RestMethod `
  -Method Put `
  -ContentType "application/json" `
  -Uri "http://localhost:8080/api/v1/restaurant-chains/$chainId/menu-items/$bundleId/bundle-children" `
  -Body $body

$activeBundle = Invoke-RestMethod `
  -Method Patch `
  -ContentType "application/json" `
  -Uri "http://localhost:8080/api/v1/restaurant-chains/$chainId/menu-items/$bundleId" `
  -Body (@{
    expectedVersion = $composition.version
    status = "ACTIVE"
    visibility = $true
  } | ConvertTo-Json)
```

Use active child IDs from the same chain. The returned `version` is required by
every later replacement. Then verify the path:

```powershell
Start-Sleep -Seconds 5
docker compose exec -T catalog-postgres psql -U catalog_app -d catalog_command_db `
  -c "SELECT id, status, event_type, aggregate_id FROM outbox_event ORDER BY id DESC LIMIT 5;"
docker compose exec -T effective-menu-postgres psql -U effective_menu_app -d effective_menu_db `
  -c "SELECT outlet_id, snapshot_version FROM effective_menu_snapshot ORDER BY updated_at DESC LIMIT 5;"
curl.exe -s "http://localhost:8081/api/v1/outlets/$outletId/menu"
```

Before making a later replacement, fetch the current composition and version:

```powershell
curl.exe -s "http://localhost:8080/api/v1/restaurant-chains/$chainId/menu-items/$bundleId/bundle-children"
```
