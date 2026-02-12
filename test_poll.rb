require "minitest/autorun"
require "socket"
require "json"
require "net/http"
require "webrick"
require_relative "poll"

class TestEncryptDecrypt < Minitest::Test
  def test_roundtrip
    plain = '{"emeter":{"get_realtime":{}}}'
    assert_equal plain, decrypt(encrypt(plain))
  end

  def test_roundtrip_empty
    assert_equal "", decrypt(encrypt(""))
  end

  def test_roundtrip_arbitrary
    plain = "hello world 12345 !@#"
    assert_equal plain, decrypt(encrypt(plain))
  end

  def test_encrypt_changes_bytes
    plain = "test"
    refute_equal plain.bytes, encrypt(plain).bytes
  end

  def test_encrypt_preserves_length
    plain = '{"emeter":{"get_realtime":{}}}'
    assert_equal plain.bytesize, encrypt(plain).bytesize
  end

  def test_encrypt_first_byte_uses_initial_key
    # Initial key is 171; first byte should be 171 ^ first_plain_byte
    plain = "A" # 65
    expected_first = 171 ^ 65
    assert_equal expected_first, encrypt(plain).bytes.first
  end
end

class TestTpFrame < Minitest::Test
  def test_frame_has_4_byte_length_header
    payload = "test"
    frame = tp_frame(payload)
    length = frame[0, 4].unpack1("N")
    assert_equal encrypt(payload).bytesize, length
    assert_equal encrypt(payload), frame[4..]
  end
end

class TestParseHosts < Minitest::Test
  def test_single_host
    result = parse_hosts("rack:192.168.1.1")
    assert_equal [{ label: "rack", ip: "192.168.1.1" }], result
  end

  def test_multiple_hosts
    result = parse_hosts("rack:192.168.1.1,desk:10.0.0.2")
    assert_equal 2, result.size
    assert_equal "rack", result[0][:label]
    assert_equal "192.168.1.1", result[0][:ip]
    assert_equal "desk", result[1][:label]
    assert_equal "10.0.0.2", result[1][:ip]
  end

  def test_strips_whitespace
    result = parse_hosts(" rack : 192.168.1.1 , desk : 10.0.0.2 ")
    assert_equal 2, result.size
    assert_equal "rack", result[0][:label]
    assert_equal "192.168.1.1", result[0][:ip]
  end

  def test_rejects_missing_ip
    assert_raises(ArgumentError) { parse_hosts("rack:") }
  end

  def test_rejects_missing_label
    assert_raises(ArgumentError) { parse_hosts(":192.168.1.1") }
  end

  def test_rejects_no_colon
    assert_raises(ArgumentError) { parse_hosts("just-a-label") }
  end

  def test_ipv6_address
    result = parse_hosts("rack:::1")
    assert_equal "rack", result[0][:label]
    assert_equal "::1", result[0][:ip]
  end
end

class TestBuildLine < Minitest::Test
  def test_format
    realtime = {
      "voltage_mv" => 121_300,
      "current_ma" => 1_250,
      "power_mw"   => 151_625,
      "total_wh"   => 42
    }
    line = build_line("myplug", realtime, 1_700_000_000)
    assert_equal "energy,plug=myplug voltage=121.3,current=1.25,power=151.625,total_wh=42 1700000000", line
  end

  def test_zero_values
    realtime = {
      "voltage_mv" => 0,
      "current_ma" => 0,
      "power_mw"   => 0,
      "total_wh"   => 0
    }
    line = build_line("off", realtime, 0)
    assert_equal "energy,plug=off voltage=0.0,current=0.0,power=0.0,total_wh=0 0", line
  end
end

class TestQueryPlug < Minitest::Test
  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
  end

  def teardown
    @server.close unless @server.closed?
    @thread&.kill
  end

  def serve_response(json_str)
    @thread = Thread.new do
      client = @server.accept
      client.recv(4096) # consume the request
      client.write(tp_frame(json_str))
      client.close
    end
  end

  def test_successful_query
    response = {
      "emeter" => {
        "get_realtime" => {
          "voltage_mv" => 120_100,
          "current_ma" => 500,
          "power_mw"   => 60_050,
          "total_wh"   => 10,
          "err_code"   => 0
        }
      }
    }
    serve_response(response.to_json)
    result = query_plug("127.0.0.1", @port, 2)
    assert_equal response, result
  end

  def test_receives_emeter_request
    received = nil
    @thread = Thread.new do
      client = @server.accept
      raw = client.recv(4096)
      # Skip 4-byte length header, decrypt the rest
      received = decrypt(raw[4..])
      client.write(tp_frame('{"emeter":{"get_realtime":{"err_code":0}}}'))
      client.close
    end
    query_plug("127.0.0.1", @port, 2)
    @thread.join(2)
    assert_equal '{"emeter":{"get_realtime":{}}}', received
  end

  def test_connection_refused
    @server.close
    assert_raises(Errno::ECONNREFUSED) { query_plug("127.0.0.1", @port, 1) }
  end

  def test_empty_response
    @thread = Thread.new do
      client = @server.accept
      client.recv(4096)
      client.close
    end
    assert_raises(RuntimeError, /Empty response/) { query_plug("127.0.0.1", @port, 1) }
  end
end

class TestWriteInflux < Minitest::Test
  def setup
    @server = WEBrick::HTTPServer.new(Port: 0, Logger: WEBrick::Log.new("/dev/null"), AccessLog: [])
    @port = @server.config[:Port]
    @captured = {}

    @server.mount_proc("/api/v2/write") do |req, res|
      @captured[:method] = req.request_method
      @captured[:body] = req.body
      @captured[:auth] = req["Authorization"]
      @captured[:content_type] = req["Content-Type"]
      @captured[:query] = URI.decode_www_form(req.query_string || "").to_h
      res.status = @response_status || 204
      res.body = @response_body || ""
    end

    @thread = Thread.new { @server.start }
  end

  def teardown
    @server.shutdown
    @thread.join(2)
  end

  def test_sends_correct_request
    lines = ["energy,plug=rack voltage=120.1,current=0.5,power=60.05,total_wh=10 1700000000"]
    write_influx("http://127.0.0.1:#{@port}", "my-token", "myorg", "mybucket", lines)

    assert_equal "POST", @captured[:method]
    assert_equal "Token my-token", @captured[:auth]
    assert_equal "text/plain", @captured[:content_type]
    assert_equal lines.first, @captured[:body]
    assert_equal "myorg", @captured[:query]["org"]
    assert_equal "mybucket", @captured[:query]["bucket"]
    assert_equal "s", @captured[:query]["precision"]
  end

  def test_multiple_lines
    lines = [
      "energy,plug=a voltage=120.0 1",
      "energy,plug=b voltage=121.0 2"
    ]
    write_influx("http://127.0.0.1:#{@port}", "tok", "org", "bkt", lines)
    assert_equal lines.join("\n"), @captured[:body]
  end

  def test_raises_on_server_error
    @response_status = 500
    @response_body = "internal error"
    assert_raises(RuntimeError, /InfluxDB write failed/) do
      write_influx("http://127.0.0.1:#{@port}", "tok", "org", "bkt", ["x"])
    end
  end

  def test_special_chars_in_org_and_bucket
    write_influx("http://127.0.0.1:#{@port}", "tok", "my org", "my bucket", ["x"])
    assert_equal "my org", @captured[:query]["org"]
    assert_equal "my bucket", @captured[:query]["bucket"]
  end
end
