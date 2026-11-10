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
