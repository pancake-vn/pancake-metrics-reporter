defmodule MetricsCake.ProcStatsTest do
  use ExUnit.Case, async: true

  alias MetricsCake.ProcStats

  @netdev_header """
  Inter-|   Receive                                                |  Transmit
   face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  """
  @snmp_names "Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts InCsumErrors"
  @netstat_names "TcpExt: SyncookiesSent ListenOverflows ListenDrops"

  defp disk(fields), do: ProcStats.parse_diskstats("   8       0 vda 1 0 2 3 4 0 5 6 0 7 8\n 252      16 vdb #{fields} 0 0 0 0\n", "vdb")

  defp tcp(tcp, tcp_ext) do
    Map.merge(
      ProcStats.parse_kv("#{@snmp_names}\nTcp: #{tcp}\nUdp: InDatagrams\nUdp: 1\n", "Tcp"),
      ProcStats.parse_kv("#{@netstat_names}\nTcpExt: #{tcp_ext}\nMPTcpExt: MPCapableSYNRX\nMPTcpExt: 0\n", "TcpExt")
    )
  end

  defp values(metrics), do: Map.new(metrics, &{&1.type, &1.value})

  test "disk_rates/3: throughput, IOPS, await, util and in-flight from two /proc/diskstats snapshots" do
    # +100 reads / 2048 sectors / 300ms, +50 writes / 4096 sectors / 500ms, 3 IO đang chạy, +1000ms bận
    metrics =
      ProcStats.disk_rates(
        disk("1000 0 8000 500 2000 0 16000 4000 0 6000 9000"),
        disk("1100 0 10048 800 2050 0 20096 4500 3 7000 9900"),
        2.0
      )

    assert Enum.all?(metrics, &(&1.labels == %{device: "vdb"}))

    assert values(metrics) == %{
             "disk_read" => 524_288.0,
             "disk_write" => 1_048_576.0,
             "disk_read_ops" => 50.0,
             "disk_write_ops" => 25.0,
             "disk_read_await" => 3.0,
             "disk_write_await" => 10.0,
             "disk_util" => 50.0,
             "disk_in_flight" => 3.0
           }
  end

  test "disk_rates/3: no IO in the window => await 0, no division error; unknown device => []" do
    idle = disk("1 0 1 1 1 0 1 1 0 1 1")
    assert values(ProcStats.disk_rates(idle, idle, 2.0))["disk_read_await"] == 0.0
    assert ProcStats.disk_rates(nil, nil, 2.0) == []
  end

  test "tcp_rates/3: retransmits, retransmit ratio, listen overflows, established" do
    metrics =
      ProcStats.tcp_rates(
        tcp("1 200 120000 -1 10 20 0 0 42 1000 10000 100 0 0 0", "0 7 7"),
        tcp("1 200 120000 -1 10 20 0 0 50 1000 11000 110 0 0 0", "0 13 13"),
        2.0
      )

    assert values(metrics) == %{
             "tcp_retrans" => 5.0,
             "tcp_retrans_ratio" => 1.0,
             "tcp_listen_overflows" => 3.0,
             "tcp_established" => 50.0
           }

    idle = tcp("1 200 120000 -1 10 20 0 0 1 1 1 1 0 0 0", "0 0 0")
    assert values(ProcStats.tcp_rates(idle, idle, 2.0))["tcp_retrans_ratio"] == 0.0
  end

  test "parse_netdev/1 keeps physical interfaces and drops lo/veth/docker/br-" do
    counters = "1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16"
    text = @netdev_header <> "    lo: #{counters}\n  eth0: #{counters}\nveth1a2b: #{counters}\ndocker0: #{counters}\nbr-1f2e: #{counters}\n  eth1:#{counters}\n"

    assert ProcStats.parse_netdev(text) |> Map.keys() |> Enum.sort() == ["eth0", "eth1"]
    assert ProcStats.parse_netdev(text)["eth1"] |> Enum.at(8) == 9
  end

  test "storage_device/2 finds the device mounted at the given path" do
    mounts = "/dev/vda1 / ext4 rw 0 0\n/dev/vdb /cdn-storage ext4 rw,noatime 0 0\n"
    assert ProcStats.storage_device(mounts, "/cdn-storage") == "vdb"
    assert ProcStats.storage_device(mounts, "/") == "vda1"
    assert ProcStats.storage_device(mounts, "/missing") == nil
  end

  @tag :linux
  test "network/0 keeps the legacy %{direction, interface, value} shape (reads real /proc)" do
    if File.exists?("/proc/net/dev") do
      for entry <- ProcStats.network() do
        assert %{direction: direction, interface: iface, value: value} = entry
        assert direction in ["ingress", "egress"] and is_binary(iface) and is_float(value)
      end
    end
  end
end
