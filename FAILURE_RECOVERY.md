# Failure and recovery runbook

This runbook describes the expected behavior of the Release 1.0 local platform when
one dependency is unavailable. PostgreSQL is the source of truth for each service;
Redis is only a derived serving cache.

## Start and inspect the stack

```powershell
docker compose up -d --build
docker compose ps
curl.exe -s http://localhost:8080/actuator/health
curl.exe -s http://localhost:8081/actuator/health
```

## PostgreSQL outage

Stop one database, for example Effective Menu PostgreSQL:

```powershell
docker compose stop effective-menu-postgres
curl.exe -s http://localhost:8081/actuator/health/liveness
curl.exe -s http://localhost:8081/actuator/health/readiness
```

Expected result: liveness remains `UP`, readiness becomes `DOWN`, and the read model is
not modified. Restore the dependency with:

```powershell
docker compose start effective-menu-postgres
docker compose ps effective-menu-postgres
```

## Kafka outage

```powershell
docker compose stop kafka
curl.exe -s http://localhost:8081/actuator/health/liveness
curl.exe -s http://localhost:8081/actuator/health/readiness
```

Expected result: liveness remains `UP`, while readiness becomes `DOWN` because the
custom Kafka health indicator cannot obtain broker metadata. Existing outbox records
are preserved for later delivery; no event is intentionally discarded.

Restore Kafka:

```powershell
docker compose start kafka
docker compose ps kafka
```

## Redis outage

```powershell
docker compose stop redis
curl.exe -s http://localhost:8081/actuator/health/readiness
curl.exe -i http://localhost:8081/api/v1/outlets/1/menu
curl.exe -s http://localhost:8081/actuator/effective-menu
```

Expected result: readiness remains `UP`, the customer API returns the same business
response from PostgreSQL, and cache read-failure/miss metrics increase. Redis failure
does not change menu contents or cause data loss.

Restore Redis:

```powershell
docker compose start redis
docker compose ps redis
curl.exe -s http://localhost:8081/api/v1/outlets/1/menu
curl.exe -s http://localhost:8081/actuator/effective-menu
```

The first request after recovery can repopulate Redis; a later request can be served
from the cache.

## Event-processing failures

Malformed, duplicate, and stale Kafka events are handled by the Effective Menu
consumer tests. A malformed event is retried according to the configured error handler,
then sent to the DLQ after retry exhaustion. Duplicate event IDs and stale aggregate
versions do not create another business update.

Inspect the relevant evidence with:

```powershell
curl.exe -s http://localhost:8081/actuator/effective-menu
docker compose logs effective-menu-service --tail=100
```

## Rebuild after source changes

Compose uses built images. Rebuild the affected services after Java or property changes:

```powershell
docker compose up -d --build catalog-service effective-menu-service
```

The health endpoint exposes dependency component names and statuses without exposing
exception details or credentials. After pushing a checkpoint, verify that the GitHub
Actions workflow is green for the exact commit; local Maven success does not replace
the remote CI check.

## CI evidence

The integration workflow checks out both service branches, runs each complete Maven test
suite, builds the Docker stack, runs the reconciliation smoke test, and always tears
down the stack. Docker-dependent tests remain clearly separated from ordinary unit
tests by their Testcontainers usage.
