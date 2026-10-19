# Shopble — Stablecoin Checkout & Order Reconciliation on Stellar

A buyer who already holds a stablecoin on Stellar pays for **one specific order**, and the
system proves — deterministically, and verifiably on the ledger — that the payment satisfies
that order.

How it works: a buyer connects a wallet and creates an order intent. The order id *is* the
Stellar memo (a ksuid is 27 bytes, one under the 28-byte `MEMO_TEXT` ceiling), so there is no
lookup table to drift. A watcher polls Horizon for payments to the destination account, stores
the raw evidence, and a matcher returns exactly one verdict: `matched`, or one of five named
rejections — `underpayment`, `wrong_asset`, `wrong_destination`, `wrong_buyer_wallet`,
`invalid_memo`. Each verdict is written to a Soroban contract that enforces the state machine
itself:

```
awaiting_payment → payment_detected → validated
                                    → rejected(reason)
```

Only `validated` qualifies for fulfilment. Postgres is the system of record; the chain is a
verifiable copy. Go backend, React frontend, Rust contract.

> **TESTNET ONLY.** The app **refuses to boot** if `STELLAR_CONFIG` points at the public
> network (`project/shopble/lib/libstellar/config.go`). No real value moves.

## Asset and accounts

| | |
|---|---|
| Asset code | `USDC` |
| Issuer | `GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5` |
| Network passphrase | `Test SDF Network ; September 2015` |
| Horizon | `https://horizon-testnet.stellar.org` |
| Soroban RPC | `https://soroban-testnet.stellar.org` |
| Destination account | `GDE7NZL663QM3CSG3V7XPIVSYFQXXI7VWSCSBGQAPLZ2MVSMOJFLQHDI` |
| Order-status contract | `CCVC5G47V7EBMZNCRO2SBIJRD67RTMIZMOL75UEAIHCAF3HHXXNQNHCO` |
| Contract operator | `GDE7NZL663QM3CSG3V7XPIVSYFQXXI7VWSCSBGQAPLZ2MVSMOJFLQHDI` |

> **The destination account must hold a trustline to the USDC issuer above.** Stellar will not
> let an account receive a non-native asset without one — the payment fails on the ledger with
> `op_no_trust` and no backend change can fix it.

> The destination account and the contract operator are currently the **same key**: it both
> receives funds and signs status writes. Acceptable for a prototype, not for production.

## Run locally

```bash
docker compose up -d --build
```

Or on the host:

```bash
cp config.example.yml config.yml          # fill asset_issuer + destination_account
go build --tags shopble -o shopble ./main.go    # the `shopble` tag is MANDATORY
CONFIG_PATH=./config.yml ./shopble migrate
export SHOPBLE_OPERATOR_SECRET=$(stellar keys secret shopble-operator)
CONFIG_PATH=./config.yml ./shopble serve --port 8080 --interval 3
```

Frontend separately: `cd project/shopble/web && cp .env.example .env && npm ci && npm run dev`.

Health: <http://localhost:8080/health> · Swagger: <http://localhost:8080/swagger/index.html>

## Deployment

Two images, two services. `docker/app/shopble.dockerfile` builds a static Go binary onto
distroless; `docker/web/shopble-web.dockerfile` builds the bundle with node and serves it
with nginx. `docker-compose.yml` works for both local compose and a swarm stack.

### 1. Configuration

```bash
cp .env.example .env
cp config.example.yml config.yml
```

Split by design:

- **`config.yml`** holds everything under `STELLAR_CONFIG` — read through `viper.UnmarshalKey`,
  so it **must** be in the file and cannot come from the environment.
- **`.env`** holds the credentials: `DB_CONNECTION` (viper `AutomaticEnv` overrides the
  top-level key) and `SHOPBLE_OPERATOR_SECRET`. Never commit it.

`SHOPBLE_CONFIG` must be an **absolute** path on swarm — swarm does not resolve relative bind
mounts. `DB_CONNECTION` points at the postgres service name and its **internal** port 5432,
not a published host port.

The operator secret never goes in a file or an image layer:

```bash
SHOPBLE_OPERATOR_SECRET=$(stellar keys secret shopble-operator)
```

If it is missing while `contract_id` is set, the watcher **dies at boot** on purpose. Skipping
the write silently would leave orders `validated` in Postgres but absent from the chain, which
only surfaces when someone goes looking for the evidence. To run deliberately without chain
writes, pass `--no-chain`.

### 2. Build and deploy

Local compose builds from the file. On swarm, build and push first — `docker stack deploy`
never builds, and `SHOPBLE_IMAGE` / `SHOPBLE_WEB_IMAGE` must be registry paths:

```bash
set -a; . ./.env; set +a     # stack deploy interpolates from the shell, not from .env

docker build -f docker/app/shopble.dockerfile -t "$SHOPBLE_IMAGE" .
docker build -f docker/web/shopble-web.dockerfile -t "$SHOPBLE_WEB_IMAGE" \
  --build-arg VITE_API_BASE="$VITE_API_BASE" --build-arg VITE_HORIZON="$VITE_HORIZON" .
docker push "$SHOPBLE_IMAGE" && docker push "$SHOPBLE_WEB_IMAGE"

docker stack deploy -c docker-compose.yml shopble
```

### 3. Migrate before the first deploy

A schema migration has no one-shot equivalent inside a stack. Run it as a plain container on
the same network, **before** deploying:

```bash
docker run --rm --network db_private_network \
  -e DB_CONNECTION="$DB_CONNECTION" \
  -v "$SHOPBLE_CONFIG":/etc/shopble/config.yml:ro \
  "$SHOPBLE_IMAGE" migrate
```

### 4. Front nginx

`api` publishes on `${API_PORT}` (8081), `web` on `${WEB_PORT}` (3000). Put a TLS-terminating
nginx in front of one hostname and route `/api` and `/health` to 8081, everything else to 3000.
That makes the app **same-origin**, so the API's CORS middleware never comes into play.

TLS is not optional: **Freighter only injects on https or `localhost`**. A deployment served
over plain http looks fine and then fails to connect a wallet.

The `web` container also proxies `/api` to `api` internally, so port 3000 works on its own
before the front nginx exists. Once the front nginx routes `/api` itself that block in
`docker/web/nginx.conf` is redundant — harmless, and safe to delete.

### Things that decide whether it actually works

- **Run `serve`, not `api http`.** The image's default CMD is `api http`, which starts the API
  with **no watcher**: nothing reads the ledger, no payment is ever detected, and `/health`
  still answers `healthy`. The command override in `docker-compose.yml` is what makes the
  deployment complete. Split the two only when running more than one API replica.
- **Exactly one watcher instance.** The Horizon cursor is per-stream and the chain-write retry
  counter is an in-memory map, so a second replica double-processes the ledger. The compose
  file pins `replicas: 1` with `order: stop-first` for this reason.
- **`VITE_API_BASE` stays empty.** Vite inlines env vars at **build** time, so these are build
  args, not runtime environment — repointing the bundle means rebuilding the image. Empty makes
  the app call `/api` on whatever origin served it, which is correct both behind the front nginx
  and on port 3000 directly. An absolute URL brings CORS back and pins the bundle to one host.
- **Keep `RELEASE_MODE` off `prod`** unless the frontend is same-origin. At `prod` the router
  drops the CORS middleware entirely and hides Swagger
  (`project/shopble/services/api/routes.go`).
- **Redis is not used.** `apiPrerun` and `watchPrerun` initialise the database and the Stellar
  config, nothing else. The `CACHE_DB` / `LOCK_DB` blocks are parsed and never dialled; drop
  redis from the deployment and leave them in place.

### Verify

```bash
docker service logs -f shopble_api
```

Expect `watcher: stream="payments" dest=GDE7… interval=3s`. If that line is absent, the command
override did not take and nothing is watching the ledger.

### On-chain entries expire after ~7 days

Soroban charges for storage by time. The contract does not call `extend_ttl`, so every
persistent entry gets the network minimum at write time — **120,960 ledgers ≈ 7 days** since
the last write — and is then archived. The backend **cannot restore an archived entry**:
`libsoroban` runs simulate → sign → send and ignores the `restorePreamble` the simulation
returns, so chain writes fail until someone restores it from the CLI.

Any CLI invoke restores and extends automatically. Run this after any idle week:

```bash
stellar contract invoke --id <contract_id> --source-account shopble-operator \
  --network testnet -- get_operator
```

Expiry does not touch history — Stellar Expert transaction links last forever. Only the
re-readable state expires.
