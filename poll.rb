require "socket"
require "json"
require "net/http"
require "uri"
require "logger"

LOG = Logger.new($stdout)
LOG.level = Logger::INFO

# ── TP-Link XOR protocol ────────────────────────────────────────────

def encrypt(plain)
  key = 171
  plain.bytes.map { |b| key = key ^ b }.pack("C*")
end

def decrypt(cipher)
  key = 171
  cipher.bytes.map { |b| d = key ^ b; key = b; d }.pack("C*")
end

def tp_frame(data)
  encrypted = encrypt(data)
  [encrypted.bytesize].pack("N") + encrypted
end

def query_plug(host, port = 9999, timeout = 5)
  payload = '{"emeter":{"get_realtime":{}}}'

  sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
  addr = Socket.sockaddr_in(port, host)

  begin
    sock.connect_nonblock(addr)
  rescue IO::WaitWritable
    IO.select(nil, [sock], nil, timeout) or raise "Connection to #{host} timed out"
    begin
      sock.connect_nonblock(addr)
    rescue Errno::EISCONN
      # connected
    end
  end

  sock.write(tp_frame(payload))

  IO.select([sock], nil, nil, timeout) or raise "Read timeout from #{host}"
  raw = sock.recv(4096)
  raise "Empty response from #{host}" if raw.nil? || raw.empty?

  length = raw[0, 4].unpack1("N")
  body = raw[4..]

  while body.bytesize < length
    IO.select([sock], nil, nil, timeout) or break
    chunk = sock.recv(4096)
    break if chunk.nil? || chunk.empty?
    body += chunk
  end

  JSON.parse(decrypt(body))
ensure
  sock&.close
end

# ── InfluxDB 2.x line-protocol writer ───────────────────────────────

def write_influx(url, token, org, bucket, lines)
  uri = URI("#{url}/api/v2/write?org=#{URI.encode_www_form_component(org)}&bucket=#{URI.encode_www_form_component(bucket)}&precision=s")
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Token #{token}"
  req["Content-Type"] = "text/plain"
  req.body = lines.join("\n")

  resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 5) { |http| http.request(req) }

  unless resp.is_a?(Net::HTTPSuccess) || resp.code == "204"
    raise "InfluxDB write failed (#{resp.code}): #{resp.body}"
  end
end

# ── Helpers ──────────────────────────────────────────────────────────

def parse_hosts(raw)
  raw.split(",").map do |entry|
    label, ip = entry.strip.split(":", 2)
    label = label&.strip
    ip = ip&.strip
    raise ArgumentError, "Bad HS110_HOSTS entry: #{entry}" unless label && !label.empty? && ip && !ip.empty?
    { label: label, ip: ip }
  end
end

def build_line(label, realtime, ts)
  voltage  = realtime["voltage_mv"] / 1000.0
  current  = realtime["current_ma"] / 1000.0
  power    = realtime["power_mw"]   / 1000.0
  total_wh = realtime["total_wh"]
  "energy,plug=#{label} voltage=#{voltage},current=#{current},power=#{power},total_wh=#{total_wh} #{ts}"
end

# ── Main ─────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  hosts_raw = ENV.fetch("HS110_HOSTS") { abort "HS110_HOSTS is required (e.g. label1:ip1,label2:ip2)" }
  INFLUX_URL    = ENV.fetch("INFLUXDB_URL")    { abort "INFLUXDB_URL is required" }
  INFLUX_TOKEN  = ENV.fetch("INFLUXDB_TOKEN")  { abort "INFLUXDB_TOKEN is required" }
  INFLUX_ORG    = ENV.fetch("INFLUXDB_ORG")    { abort "INFLUXDB_ORG is required" }
  INFLUX_BUCKET = ENV.fetch("INFLUXDB_BUCKET") { abort "INFLUXDB_BUCKET is required" }
  POLL_INTERVAL = Integer(ENV.fetch("POLL_INTERVAL", "10"))

  plugs = parse_hosts(hosts_raw)
  LOG.info "Starting HS110 poller — #{plugs.size} plug(s), interval #{POLL_INTERVAL}s"

  loop do
    lines = []
    ts = Time.now.to_i

    plugs.each do |plug|
      begin
        data = query_plug(plug[:ip])
        realtime = data.dig("emeter", "get_realtime")
        raise "Emeter error (code #{realtime["err_code"]})" if realtime["err_code"] != 0

        lines << build_line(plug[:label], realtime, ts)
        LOG.info "[#{plug[:label]}] #{realtime["voltage_mv"] / 1000.0}V  #{realtime["current_ma"] / 1000.0}A  #{realtime["power_mw"] / 1000.0}W  #{realtime["total_wh"]}Wh"
      rescue => e
        LOG.error "[#{plug[:label]}] #{e.class}: #{e.message}"
      end
    end

    unless lines.empty?
      begin
        write_influx(INFLUX_URL, INFLUX_TOKEN, INFLUX_ORG, INFLUX_BUCKET, lines)
      rescue => e
        LOG.error "InfluxDB: #{e.class}: #{e.message}"
      end
    end

    sleep POLL_INTERVAL
  end
end
