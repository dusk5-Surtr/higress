# Runtime verification evidence — ai-token-ratelimit per-IP source

Red/green comparison of the two revisions through the repository's local
proxy-Wasm data path, as required by the Wasm-plugin branch of the
runtime-verification policy.

Verification scaffolding only - not part of any upstream contribution.

## 1. Pinned inputs

| Item | Value |
|---|---|
| baseline SHA | `9b232296d9f04091e22f2993ce2be69e58bd752d` (`main`) |
| fixed SHA | `ff4cf1dc295fc5813e6cc992f3d659e4ec82df8f` |
| baseline Wasm SHA-256 | `9088582C53972C2C2BFAC27ED39807C6FDA3FB3349ACD12058A246F4FB612F10` (8,130,341 bytes) |
| fixed Wasm SHA-256 | `A5C185DF5267F51A191C3C69156FA8D404C1537722AD814C83D0992E370E6757` (8,138,101 bytes) |
| gateway image | `higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/gateway:2.1.9` |
| gateway digest | `sha256:d80b4842303ecd082716fbe598ab7744f495a0b8445fa51cab2d6703d32101d3` |
| upstream image | `mccutchen/go-httpbin:v2.14.0` |
| upstream digest | `sha256:1b9335226caf3c9b6ab89e1230b82355aa81e109ffbc057a9fd9d212ca65487b` |
| redis image | `redis:7-alpine` |
| redis digest | `sha256:858f009f9709ce576febc734aa78b8f6d624b82571f9ddb6bda4377c833b3499` |
| build command | `GOOS=wasip1 GOARCH=wasm go build -buildmode=c-shared -o ./main.wasm .` |
| harness | `docs/developers/wasm-runtime-verification/` |
| Envoy version (in image) | `ced6d8167a01fe1c1630b3df0ac39e1b563f05dc/1.27.7/Clean/RELEASE/BoringSSL` |

The two modules are provably different builds: different SHA-256 and different
byte count, both produced from the same toolchain with only the reviewed source
diff between them.

## 2. Plugin configuration (identical for both variants)

```json
{
  "rule_name": "ai-token-ip-header-limit",
  "rule_items": [
    {
      "limit_by_per_ip": "from-header-x-real-ip",
      "limit_keys": [
        { "key": "192.168.1.0/24", "token_per_minute": 300 }
      ]
    }
  ],
  "redis": { "service_name": "redis.static", "service_port": 6379 },
  "rejected_code": 429,
  "rejected_msg": "cannot resolve client ip"
}
```

## 3. Requests

Ten requests per variant against `http://127.0.0.1:10000/`, each carrying
`X-Request-ID` (used as the access-log correlation id) and
`X-Verification-Iteration`.

| Request id | `x-real-ip` |
|---|---|
| `malformed-bracket` | `]` |
| `malformed-bracket-port` | `]:8080` |
| `malformed-bracket-junk` | `]junk` |
| `malformed-not-an-ip` | `not-an-ip` |
| `header-absent` | *(header omitted)* |
| `valid-ip` | `192.168.1.10` |
| `valid-ip-with-port` | `192.168.1.10:443` |
| `repeat-bracket-1..3` | `]` (three repeats for determinism) |

## 4. Baseline — red

Access log, all ten requests (`UPSTREAM` is the upstream host Envoy forwarded to):

```
RID=malformed-bracket      ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=malformed-bracket-port ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=malformed-bracket-junk ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=malformed-not-an-ip    ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=header-absent          ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=valid-ip               ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=valid-ip-with-port     ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=repeat-bracket-1       ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=repeat-bracket-2       ITER=2 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=repeat-bracket-3       ITER=3 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
```

Every request reached the upstream. The plugin log shows the panic, recovered by
the wasm-go wrapper, correlated by request id:

```
[ai-token-ratelimit] [nil] [malformed-bracket]      recovered from panic runtime error: slice bounds out of range [1:0], stack: goroutine 1 [running]:
[ai-token-ratelimit] [nil] [malformed-bracket-port] recovered from panic runtime error: slice bounds out of range [1:0], stack: goroutine 1 [running]:
[ai-token-ratelimit] [nil] [malformed-bracket-junk] recovered from panic runtime error: slice bounds out of range [1:0], stack: goroutine 1 [running]:
[ai-token-ratelimit] [nil] [repeat-bracket-1]       recovered from panic runtime error: slice bounds out of range [1:0], stack: goroutine 1 [running]:
[ai-token-ratelimit] [nil] [repeat-bracket-2]       recovered from panic runtime error: slice bounds out of range [1:0], stack: goroutine 1 [running]:
[ai-token-ratelimit] [nil] [repeat-bracket-3]       recovered from panic runtime error: slice bounds out of range [1:0], stack: goroutine 1 [running]:
```

**Both halves of the defect appear together**: the panic fires, the wrapper
recovers it, `onHttpRequestHeaders` returns the zero value `ActionContinue`, and
the request is forwarded with no counter consulted. Six panics for exactly the six
inputs that carry a leading `]`; `not-an-ip` and the absent header do not panic,
which matches the code path (`ParseIP` returns `not-an-ip` unchanged, and an absent
header fails before `ParseIP` is reached).

## 5. Fixed — green

```
RID=malformed-bracket      ITER=1 CODE=429 UPSTREAM=- SENT=24
RID=malformed-bracket-port ITER=1 CODE=429 UPSTREAM=- SENT=24
RID=malformed-bracket-junk ITER=1 CODE=429 UPSTREAM=- SENT=24
RID=malformed-not-an-ip    ITER=1 CODE=429 UPSTREAM=- SENT=24
RID=header-absent          ITER=1 CODE=429 UPSTREAM=- SENT=24
RID=valid-ip               ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=valid-ip-with-port     ITER=1 CODE=200 UPSTREAM=172.18.0.3:8080 SENT=11839
RID=repeat-bracket-1       ITER=1 CODE=429 UPSTREAM=- SENT=24
RID=repeat-bracket-2       ITER=2 CODE=429 UPSTREAM=- SENT=24
RID=repeat-bracket-3       ITER=3 CODE=429 UPSTREAM=- SENT=24
```

- no panic anywhere in the run (`slice bounds` occurs 0 times);
- the five unresolvable inputs are rejected with the configured `429` and
  `UPSTREAM=-`, i.e. the upstream was never contacted;
- the two resolvable inputs still reach the upstream with the same body size as
  the baseline, so valid traffic is unaffected;
- the three repeats are identical, so the result is deterministic.

Rejection log, one line per rejected request:

```
ai-token-ratelimit: rejecting request, cannot resolve client ip for rule "from-header-x-real-ip": invalid ip[]]
ai-token-ratelimit: rejecting request, cannot resolve client ip for rule "from-header-x-real-ip": invalid ip[]:8080]
ai-token-ratelimit: rejecting request, cannot resolve client ip for rule "from-header-x-real-ip": invalid ip[]junk]
ai-token-ratelimit: rejecting request, cannot resolve client ip for rule "from-header-x-real-ip": invalid ip[not-an-ip]
ai-token-ratelimit: rejecting request, cannot resolve client ip for rule "from-header-x-real-ip": error status returned by host: not found
```

The rejection body is the configured `rejected_msg` (24 bytes,
`cannot resolve client ip`), which confirms the response comes from the plugin
rather than from the upstream.

## 6. Side-by-side

| `x-real-ip` | baseline | fixed |
|---|---|---|
| `]` | 200, forwarded | **429, not forwarded** |
| `]:8080` | 200, forwarded | **429, not forwarded** |
| `]junk` | 200, forwarded | **429, not forwarded** |
| `not-an-ip` | 200, forwarded | **429, not forwarded** |
| *(absent)* | 200, forwarded | **429, not forwarded** |
| `192.168.1.10` | 200, forwarded | 200, forwarded |
| `192.168.1.10:443` | 200, forwarded | 200, forwarded |
| `]` × 3 repeats | 200, forwarded, 6 panics total | 429, not forwarded, 0 panics |

## 7. Rerun and cleanup

Runner: `C:\dev\higress-verify\run_aitoken_verify.ps1` (verification scaffolding).

```powershell
# baseline
powershell -NoProfile -ExecutionPolicy Bypass -File run_aitoken_verify.ps1 -Variant baseline
# fixed
powershell -NoProfile -ExecutionPolicy Bypass -File run_aitoken_verify.ps1 -Variant fixed
```

Each run sets `WASM_PATH` to the repository-relative module for that variant,
brings the harness up with `docker compose -f compose.ai-token-ratelimit-verify.yaml up -d`,
probes, stops Envoy to flush its buffered stdout, collects logs, then runs
`docker compose ... down --volumes --remove-orphans` in a `finally` block.

Cleanup observed in both runs:

```
containers left: none
listeners left on 10000: none
```

## 8. Deviations from the repository harness, and why

All three are recorded because the evidence has to describe the configuration it
actually ran, not the configuration the README shows.

1. **`internal: true` removed from the compose network.** `compose.yaml` marks the
   network internal, but the README drives the probes with host-side
   `curl http://127.0.0.1:${ENVOY_PORT}/...`. On Docker 29.5.2 an internal network
   leaves the published ports unbound: `docker port` prints nothing and
   `NetworkSettings.Ports` stays `{"10000/tcp":[],"9901/tcp":[]}`, so the
   documented curl cannot connect. Verified in isolation - the same
   `-p 127.0.0.1:18099:80` serves `200` on a default bridge network and exposes no
   binding on an `--internal` network. The verification compose therefore uses
   `driver: bridge`.
2. **A `redis` service plus a cluster named `outbound|6379||redis.static`.**
   wasm-go builds the Redis upstream name as `outbound|<port>||<FQDN>`
   (`pkg/wrapper/cluster_wrapper.go`), so a cluster named `redis.static` is never
   looked up. Recorded so the configuration is reproducible; the Redis counter
   itself is not exercised by this comparison, because the rejected inputs never
   reach the counter call.
3. **Upstream tag `mccutchen/go-httpbin:v2.14.0`** instead of the illustrative
   `v2.18.0` in the README: the configured registry mirror returns `403` for
   `v2.18.0`. `v2.14.0` is pinned and its digest is recorded above.

## 9. What this evidence does and does not show

Shows: for a per-IP rule whose source header is client controlled, the baseline
panics and then forwards the request without consulting the limiter, and the fixed
revision rejects the same request before any upstream call while leaving resolvable
addresses untouched. Deterministic across three repeats.

Does not show: end-to-end threshold accounting (no request in this comparison
exceeds 300 tokens/minute), and the Redis-unavailable path, which is deliberately
out of scope.
