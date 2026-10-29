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

Stop the stack:

```powershell
docker compose down
```

The Compose stack is for local integration only. Testcontainers remains responsible for automated integration tests.
