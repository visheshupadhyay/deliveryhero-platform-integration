$ErrorActionPreference = "Stop"

function Wait-ForHealth {
    param([string]$Url)

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        try {
            $health = Invoke-RestMethod -Uri $Url -Method Get
            if ($health.status -eq "UP") { return }
        } catch {
            # The service may still be starting.
        }
        Start-Sleep -Seconds 2
    }
    throw "Service did not become healthy: $Url"
}

function Invoke-PostgresSql {
    param(
        [string]$Service,
        [string]$Database,
        [string]$Sql
    )

    $user = if ($Service -eq "catalog-postgres") { "catalog_app" } else { "effective_menu_app" }
    $output = docker compose exec -T $Service psql -q -U $user -d $Database -v ON_ERROR_STOP=1 -tA -c $Sql
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL command failed for $Service" }
    return ($output | Out-String).Trim()
}

Write-Host "Waiting for Catalog and Effective Menu services..."
Wait-ForHealth "http://localhost:8080/actuator/health"
Wait-ForHealth "http://localhost:8081/actuator/health"

$suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
$catalogFixtureSql = @"
WITH chain AS (
    INSERT INTO restaurant_chain (display_name, business_code)
    VALUES ('Smoke Test Chain', 'SMOKE-CHAIN-$suffix')
    RETURNING id
), outlet AS (
    INSERT INTO outlet (display_name, outlet_code, restaurant_chain_id, currency, status)
    SELECT 'Smoke Test Outlet', 'SMOKE-OUTLET-$suffix', id, 'EUR', 'ACTIVE'
    FROM chain
    RETURNING id, restaurant_chain_id
)
INSERT INTO menu_item (
    item_name, item_price, created_at, updated_at, outlet_id,
    business_code, status, visibility, availability, version, restaurant_chain_id
)
SELECT 'Smoke Test Burger', 10.00, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, outlet.id,
       'SMOKE-ITEM-$suffix', 'ACTIVE', TRUE, TRUE, 0, outlet.restaurant_chain_id
FROM outlet
RETURNING id, outlet_id;
"@

$ids = Invoke-PostgresSql "catalog-postgres" "catalog_command_db" $catalogFixtureSql
$idParts = $ids.Split('|')
if ($idParts.Count -ne 2) { throw "Could not read generated Catalog IDs: $ids" }
$menuItemId = [long]$idParts[0]
$outletId = [long]$idParts[1]

Write-Host "Checking missing snapshot behavior..."
$missing = Invoke-RestMethod -Uri "http://localhost:8080/api/v1/reconciliation/menu-items/$menuItemId/outlets/$outletId" -Method Get
if ($missing.resultType -ne "MISSING_SNAPSHOT" -or $null -ne $missing.effectiveVersion) {
    throw "Expected MISSING_SNAPSHOT, received: $($missing | ConvertTo-Json -Compress)"
}

$snapshotSql = "
INSERT INTO effective_menu_snapshot (outlet_id, snapshot_version, effective_menu, calculated_at, updated_at)
VALUES ($outletId, 0,
        jsonb_build_object('items', jsonb_build_array(jsonb_build_object(
            'id', $menuItemId, 'price', 10.00, 'availability', true, 'visibility', true
        ))), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
ON CONFLICT (outlet_id) DO UPDATE SET
    snapshot_version = EXCLUDED.snapshot_version,
    effective_menu = EXCLUDED.effective_menu,
    calculated_at = EXCLUDED.calculated_at,
    updated_at = EXCLUDED.updated_at;
"
Invoke-PostgresSql "effective-menu-postgres" "effective_menu_db" $snapshotSql | Out-Null

Write-Host "Checking matching snapshot behavior..."
$match = Invoke-RestMethod -Uri "http://localhost:8080/api/v1/reconciliation/menu-items/$menuItemId/outlets/$outletId" -Method Get
if ($match.resultType -ne "MATCH" -or $match.catalogVersion -ne 0 -or $match.effectiveVersion -ne 0) {
    throw "Expected MATCH, received: $($match | ConvertTo-Json -Compress)"
}

Write-Host "Reconciliation smoke test passed: MISSING_SNAPSHOT -> MATCH"
