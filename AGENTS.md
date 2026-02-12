# Agents Guide

## Project overview

Single-file Ruby poller that reads energy data from TP-Link HS110 smart plugs over TCP and writes it to InfluxDB 2.x. Runs as a long-lived loop inside Docker.

## Architecture

All application code lives in `poll.rb`. There are no classes — just top-level functions guarded by `if __FILE__ == $PROGRAM_NAME` so the file can be required by tests without starting the main loop.

Key layers:
- **TP-Link protocol** (`encrypt`, `decrypt`, `tp_frame`, `query_plug`) — XOR-encrypted JSON over TCP port 9999
- **InfluxDB writer** (`write_influx`) — HTTP POST of line protocol to the v2 API
- **Helpers** (`parse_hosts`, `build_line`) — config parsing and line formatting
- **Main loop** — polls all plugs, writes to InfluxDB, sleeps, repeats. Errors are caught per-plug so one failing plug doesn't affect the others.

## Conventions

- **No gems at runtime.** Only Ruby stdlib (`socket`, `json`, `net/http`, `uri`, `logger`). Test gems (`minitest`, `webrick`) are in a `:test` Bundler group.
- **No classes or modules.** Keep it as flat top-level functions. This is intentionally a simple single-file script.
- **All config comes from environment variables.** Never hardcode hosts, tokens, or URLs.
- **Errors are logged, not raised in the main loop.** Each plug and the InfluxDB write have their own rescue blocks.

## Running tests

```sh
bundle install
bundle exec ruby test_poll.rb
```

Tests use real TCP servers (for HS110 protocol) and real HTTP servers via WEBrick (for InfluxDB). No mocking libraries — just stdlib servers on random ports. Keep this pattern when adding new tests.

## Common tasks

### Adding a new field from the HS110 response
1. Add the field to `build_line` in `poll.rb`
2. Add a corresponding test case in `TestBuildLine`
3. Update the InfluxDB schema section in `README.md`

### Adding a new environment variable
1. Add the `ENV.fetch` in the `if __FILE__ == $PROGRAM_NAME` block
2. Document it in the environment variables table in `README.md`

### Supporting a different plug model
The TP-Link protocol is shared across models but the JSON command and response keys may differ. Modify `query_plug` to accept a command parameter or add a new query function. Keep the XOR encrypt/decrypt functions unchanged — they are protocol-level and model-independent.
