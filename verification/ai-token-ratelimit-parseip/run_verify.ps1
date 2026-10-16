# Runtime verification runner for the ai-token-ratelimit per-IP fix.
#
# Verification scaffolding only - not part of any upstream contribution.
#
# Runs ONE variant (baseline or fixed) of the plugin through the repository's
# local proxy-Wasm harness, sends the malformed and valid per-IP source values,
# and prints the client-visible results together with the Envoy and plugin logs.
#
# Usage:
#   pwsh -File run_aitoken_verify.ps1 -Variant baseline
#   pwsh -File run_aitoken_verify.ps1 -Variant fixed

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('baseline', 'fixed')]
    [string]$Variant,

    [int]$EnvoyPort = 10000,
    [int]$AdminPort = 9901
)

# NOTE: deliberately NOT 'Stop'. Native commands such as `docker compose` write
# ordinary progress output to stderr, and under 'Stop' PowerShell converts that
# into a terminating error, aborting the run before any probe is sent.
$ErrorActionPreference = 'Continue'

$harness = 'C:\dev\higress\docs\developers\wasm-runtime-verification'
$pluginDir = 'C:\dev\higress\plugins\wasm-go\extensions\ai-token-ratelimit'
$wasmName = "verify-$Variant.wasm"
$composeFile = 'compose.ai-token-ratelimit-verify.yaml'
$projectName = "higress-wasm-verify-aitoken-$Variant"

$env:HIGRESS_GATEWAY_IMAGE = 'higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/gateway:2.1.9'
$env:HTTPBIN_IMAGE = 'mccutchen/go-httpbin:v2.14.0'
$env:REDIS_IMAGE = 'redis:7-alpine'
$env:WASM_PATH = "../../../plugins/wasm-go/extensions/ai-token-ratelimit/$wasmName"
$env:ENVOY_PORT = "$EnvoyPort"
$env:ENVOY_ADMIN_PORT = "$AdminPort"
$env:COMPOSE_PROJECT_NAME = $projectName

function Section([string]$t) { Write-Output ""; Write-Output "=== $t ===" }

Section "0. pinned inputs"
Write-Output "variant          : $Variant"
Write-Output "wasm file        : $wasmName"
$wasmPath = Join-Path $pluginDir $wasmName
if (-not (Test-Path $wasmPath)) { throw "missing wasm: $wasmPath" }
Write-Output "wasm sha256      : $((Get-FileHash $wasmPath -Algorithm SHA256).Hash)"
Write-Output "wasm bytes       : $((Get-Item $wasmPath).Length)"
Write-Output "gateway image    : $($env:HIGRESS_GATEWAY_IMAGE)"
Write-Output "gateway digest   : $((docker image inspect --format '{{index .RepoDigests 0}}' $env:HIGRESS_GATEWAY_IMAGE 2>&1))"
Write-Output "httpbin image    : $($env:HTTPBIN_IMAGE)"
Write-Output "httpbin digest   : $((docker image inspect --format '{{index .RepoDigests 0}}' $env:HTTPBIN_IMAGE 2>&1))"
Write-Output "redis image      : $($env:REDIS_IMAGE)"
Write-Output "redis digest     : $((docker image inspect --format '{{index .RepoDigests 0}}' $env:REDIS_IMAGE 2>&1))"
Write-Output "compose file     : $composeFile"

Section "1. up"
Push-Location $harness
try {
    # Pre-flight: a leftover container from an aborted run keeps ports 10000/9901
    # bound, and the next `up` then fails to publish them. Traffic would silently
    # reach the stale container while `logs` on the new project shows nothing,
    # which is exactly the confusion this guards against.
    docker compose -f $composeFile down --volumes --remove-orphans 2>&1 | Out-Null
    $stale = docker ps -a --format '{{.Names}}' 2>&1 | Select-String -Pattern 'aitoken|wasm-verify'
    if ($stale) {
        Write-Output "  removing stale containers: $($stale -join ', ')"
        $stale | ForEach-Object { docker rm -f $_.Line 2>&1 | Out-Null }
    }

    docker compose -f $composeFile up -d 2>&1 | ForEach-Object { Write-Output "  $_" }

    # Confirm the ports really are published on this project's container before
    # probing anything.
    $published = docker port "$projectName-envoy-1" 2>&1
    Write-Output "  published ports: $(if ($published) { ($published -join '; ') } else { 'NONE - ports not published' })"
    if (-not $published) { throw "envoy ports were not published; refusing to probe" }

    Section "2. wait for envoy and plugin"
    # curl.exe rather than Invoke-WebRequest: PS 5.1's Invoke-WebRequest was
    # observed to fail against the Envoy admin socket even while Envoy was
    # serving traffic, which aborted the run before any probe was sent.
    $ready = $false
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 2
        $probe = & curl.exe -sS -o NUL -w '%{http_code}' --max-time 3 "http://127.0.0.1:$AdminPort/server_info" 2>&1
        if ("$probe" -match '200') { $ready = $true; break }
    }
    if (-not $ready) {
        Write-Output "  ENVOY ADMIN NOT REACHABLE after 60s - logs follow"
        docker compose -f $composeFile logs --no-color envoy 2>&1 | Select-Object -Last 30 | ForEach-Object { Write-Output "  $_" }
        throw "envoy did not start"
    }
    Write-Output "  envoy admin reachable on $AdminPort after $($i * 2)s"

    # the plugin logs "plugin start successfully" once the module is loaded
    $loaded = $false
    for ($i = 1; $i -le 15; $i++) {
        $logs = (docker compose -f $composeFile logs --no-color envoy 2>&1) -join "`n"
        if ($logs -match 'plugin start successfully|ai-token-ratelimit') { $loaded = $true; break }
        Start-Sleep -Seconds 2
    }
    Write-Output "  plugin log observed: $loaded"

    Section "3. probe requests"
    $base = "http://127.0.0.1:$EnvoyPort/"

    function Probe([string]$label, [string]$realIp, [int]$iteration) {
        $curlArgs = @('-sS', '-o', "$env:TEMP\probe_body_$label.txt", '-w', '%{http_code}',
                  '-H', "X-Request-ID: $label",
                  '-H', "X-VERIFICATION-ITERATION: $iteration",
                  '--max-time', '15')
        if ($realIp -ne '') { $curlArgs += @('-H', "x-real-ip: $realIp") }
        $curlArgs += $base
        $code = & curl.exe @curlArgs 2>&1
        $bodyFile = "$env:TEMP\probe_body_$label.txt"
        $len = if (Test-Path $bodyFile) { (Get-Item $bodyFile).Length } else { 0 }
        # The upstream is httpbin, whose body is an 11 KB HTML page. Printing it
        # whole buried the evidence, so only the byte count and a short prefix
        # are shown; the full bodies stay in the per-case files.
        $prefix = if ($len -gt 0) { ((Get-Content $bodyFile -Raw) -replace "`r?`n", ' ').Trim() } else { '' }
        if ($prefix.Length -gt 70) { $prefix = $prefix.Substring(0, 70) + '...' }
        Write-Output ("  [{0}] x-real-ip={1} -> HTTP {2} | body_bytes={3} | {4}" -f `
            $label, ($(if ($realIp -eq '') { '<absent>' } else { $realIp })), $code, $len, $prefix)
        return $code
    }

    Probe 'malformed-bracket'        ']'                  1
    Probe 'malformed-bracket-port'   ']:8080'             1
    Probe 'malformed-bracket-junk'   ']junk'              1
    Probe 'malformed-not-an-ip'      'not-an-ip'          1
    Probe 'header-absent'            ''                   1
    Probe 'valid-ip'                 '192.168.1.10'       1
    Probe 'valid-ip-with-port'       '192.168.1.10:443'   1

    Section "4. determinism - repeat the bracket case 3x"
    1..3 | ForEach-Object { $null = Probe "repeat-bracket-$_" ']' $_ }

    # Envoy's stdout access logger is block-buffered when stdout is a pipe, so
    # `docker compose logs` right after the probes only shows whichever lines
    # happened to fill a buffer. A graceful stop flushes the stream, so stop the
    # container before reading the logs and leave it in place for `logs`.
    Section "4b. flush logs (graceful stop)"
    docker compose -f $composeFile stop envoy 2>&1 | ForEach-Object { Write-Output "  $_" }

    Section "5. envoy access log"
    docker compose -f $composeFile logs --no-color envoy 2>&1 |
        Select-String -Pattern 'RID=' | ForEach-Object { Write-Output "  $($_.Line)" }

    Section "6. plugin log (ai-token-ratelimit lines)"
    docker compose -f $composeFile logs --no-color envoy 2>&1 |
        Select-String -Pattern 'ai-token-ratelimit|panic|slice bounds|wasm log' |
        ForEach-Object { Write-Output "  $($_.Line)" }
}
finally {
    Section "7. cleanup"
    docker compose -f $composeFile down --volumes --remove-orphans 2>&1 | ForEach-Object { Write-Output "  $_" }
    $left = docker ps -a --filter "name=$projectName" --format '{{.Names}}' 2>&1
    Write-Output "  containers left: $(if ($left) { ($left -join ', ') } else { 'none' })"
    $port = Get-NetTCPConnection -LocalPort $EnvoyPort -State Listen -ErrorAction SilentlyContinue
    Write-Output "  listeners left on ${EnvoyPort}: $(if ($port) { $port.Count } else { 'none' })"
    Pop-Location
}
