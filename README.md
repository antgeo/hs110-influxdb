# HS110 Energy Poller

Polls TP-Link HS110 smart plugs for real-time energy data and writes it to InfluxDB 2.x. Ruby script using only stdlib at runtime, packaged with Docker.

## How it works

1. Connects to each HS110 over TCP port 9999 using the TP-Link XOR-encrypted protocol
2. Sends an `emeter/get_realtime` query to read voltage, current, power, and cumulative energy
3. Writes the data as InfluxDB line protocol to the `/api/v2/write` endpoint
4. Sleeps and repeats

## Quick start

```sh
# Edit docker-compose.yml with your plug IPs, InfluxDB URL, and token
docker compose up --build
```

Or run locally:

```sh
export HS110_HOSTS="server_rack:192.168.1.100,desk:192.168.1.101"
export INFLUXDB_URL="http://localhost:8086"
export INFLUXDB_TOKEN="my-secret-token"
export INFLUXDB_ORG="myorg"
export INFLUXDB_BUCKET="energy"

ruby poll.rb
```

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `HS110_HOSTS` | yes | — | Comma-separated `label:ip` pairs |
| `INFLUXDB_URL` | yes | — | InfluxDB base URL |
| `INFLUXDB_TOKEN` | yes | — | InfluxDB API token |
| `INFLUXDB_ORG` | yes | — | InfluxDB organization |
| `INFLUXDB_BUCKET` | yes | — | InfluxDB bucket |
| `POLL_INTERVAL` | no | `10` | Seconds between polls |

## InfluxDB schema

- **Measurement:** `energy`
- **Tag:** `plug` (the label from `HS110_HOSTS`)
- **Fields:**
  - `voltage` — volts (converted from `voltage_mv`)
  - `current` — amps (converted from `current_ma`)
  - `power` — watts (converted from `power_mw`)
  - `total_wh` — cumulative watt-hours

## Running InfluxDB alongside

Uncomment the `influxdb` service in `docker-compose.yml` to run a local instance:

```sh
docker compose up --build
```

Then visit `http://localhost:8086` to access the InfluxDB UI.

## Testing

```sh
bundle install
bundle exec ruby test_poll.rb
```

Tests cover:
- XOR encrypt/decrypt roundtrips and edge cases
- TP-Link frame construction
- `HS110_HOSTS` parsing (multiple hosts, whitespace, invalid input, IPv6)
- InfluxDB line protocol formatting
- TCP communication with a mock HS110 server
- HTTP requests to a mock InfluxDB server (auth, body, query params, error handling)

## Project structure

```
poll.rb              Main polling script
test_poll.rb         Unit tests (minitest)
Gemfile              Ruby version constraint + test dependencies
Gemfile.lock         Lockfile
Dockerfile           Container image (ruby:3.3-slim)
docker-compose.yml   Compose config with example env vars
```
