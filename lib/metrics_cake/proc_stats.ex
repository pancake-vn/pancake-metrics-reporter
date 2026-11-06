defmodule MetricsCake.ProcStats do
  @moduledoc """
  Số liệu host đọc từ /proc (Linux) cho các built-in `:network`, `:network_drops`, `:disk_io`, `:tcp`.

  Đọc 2 lần cách nhau `@window_ms` rồi lấy chênh lệch => tốc độ ngay lúc đo, không giữ state giữa các lần
  poll, không cần sudo hay công cụ ngoài (iftop, iostat).

  `:network` giữ dạng cũ `%{direction, interface, value}` (byte/s). Các built-in mới trả
  `%{type, value, unit, labels}` để app đặt tên chung một kiểu, ví dụ `"cdn_" <> type` + unit.
  """

  @window_ms 2_000
  @skip_interfaces ~r/^(lo|veth|docker|br-)/

  def network do
    for {iface, direction, value} <- net_rates([{"ingress", 0}, {"egress", 8}]) do
      %{direction: direction, interface: iface, value: value}
    end
  end

  def network_drops do
    for {iface, type, value} <- net_rates([{"net_receive_drops", 3}, {"net_transmit_drops", 11}]) do
      metric(type, value, "per_second", %{interface: iface})
    end
  end

  # Thiết bị mount ở `mount` (vd "/cdn-storage"); không tìm thấy thì trả [].
  def disk_io(mount) do
    case storage_device(File.read!("/proc/mounts"), mount) do
      nil ->
        []

      device ->
        read = fn -> parse_diskstats(File.read!("/proc/diskstats"), device) end
        {before, now} = sample(read)
        disk_rates(before, now, @window_ms / 1_000)
    end
  end

  def tcp do
    read = fn ->
      Map.merge(
        parse_kv(File.read!("/proc/net/snmp"), "Tcp"),
        parse_kv(File.read!("/proc/net/netstat"), "TcpExt")
      )
    end

    {before, now} = sample(read)
    tcp_rates(before, now, @window_ms / 1_000)
  end

  # [{label, cột trong /proc/net/dev}] -> [{iface, label, giá trị/giây}]
  defp net_rates(columns) do
    read = fn -> parse_netdev(File.read!("/proc/net/dev")) end
    {before, now} = sample(read)
    secs = @window_ms / 1_000

    for {iface, now_counters} <- now,
        before_counters <- [before[iface]],
        before_counters != nil,
        {label, index} <- columns do
      {iface, label, Float.round((Enum.at(now_counters, index) - Enum.at(before_counters, index)) / secs, 2)}
    end
  end

  defp sample(read) do
    before = read.()
    Process.sleep(@window_ms)
    {before, read.()}
  end

  @doc false
  def storage_device(mounts, mount) do
    mounts
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line) do
        [source, ^mount | _] -> source
        _ -> nil
      end
    end)
    |> case do
      nil -> nil
      # /dev/mapper/x là symlink tới ../dm-0, /proc/diskstats dùng tên thật
      source -> source |> resolve_link() |> Path.basename()
    end
  end

  defp resolve_link(path) do
    case :file.read_link_all(path) do
      {:ok, target} -> List.to_string(target)
      _ -> path
    end
  end

  # 10 cột đầu sau tên device: reads, reads merged, sectors read, ms reading, writes, writes merged,
  # sectors written, ms writing, IO đang chạy, ms bận IO (Documentation/admin-guide/iostats.rst)
  @doc false
  def parse_diskstats(text, device) do
    text
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line) do
        [_major, _minor, ^device | fields] -> {device, fields |> Enum.take(10) |> Enum.map(&String.to_integer/1)}
        _ -> nil
      end
    end)
  end

  @doc false
  def parse_netdev(text) do
    for line <- String.split(text, "\n"),
        [raw_iface, counters] <- [String.split(line, ":", parts: 2)],
        iface <- [String.trim(raw_iface)],
        not Regex.match?(@skip_interfaces, iface),
        into: %{} do
      {iface, counters |> String.split() |> Enum.map(&String.to_integer/1)}
    end
  end

  # /proc/net/snmp, /proc/net/netstat: cặp dòng "<Prefix>: tên..." rồi "<Prefix>: giá trị..."
  @doc false
  def parse_kv(text, prefix) do
    [names, values] = text |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, prefix <> ":"))

    Enum.zip(tl(String.split(names)), tl(String.split(values)))
    |> Map.new(fn {name, value} -> {name, String.to_integer(value)} end)
  end

  @doc false
  def disk_rates(
        {device, [r0, _, rsec0, rms0, w0, _, wsec0, wms0, _, io0]},
        {device, [r1, _, rsec1, rms1, w1, _, wsec1, wms1, in_flight, io1]},
        secs
      ) do
    reads = r1 - r0
    writes = w1 - w0
    labels = %{device: device}

    [
      metric("disk_read", (rsec1 - rsec0) * 512 / secs, "bytes_per_second", labels),
      metric("disk_write", (wsec1 - wsec0) * 512 / secs, "bytes_per_second", labels),
      metric("disk_read_ops", reads / secs, "per_second", labels),
      metric("disk_write_ops", writes / secs, "per_second", labels),
      metric("disk_read_await", per_op(rms1 - rms0, reads), "milliseconds", labels),
      metric("disk_write_await", per_op(wms1 - wms0, writes), "milliseconds", labels),
      metric("disk_util", min((io1 - io0) / (secs * 10), 100), "percent", labels),
      metric("disk_in_flight", in_flight, "requests", labels)
    ]
  end

  def disk_rates(_before, _now, _secs), do: []

  @doc false
  def tcp_rates(before, now, secs) do
    out_segs = now["OutSegs"] - before["OutSegs"]
    retrans = now["RetransSegs"] - before["RetransSegs"]

    [
      metric("tcp_retrans", retrans / secs, "per_second", %{}),
      metric("tcp_retrans_ratio", per_op(retrans * 100, out_segs), "percent", %{}),
      # Backlog accept tràn => SYN bị bỏ, client chờ gửi lại (1s, 3s...) => request chậm dù app rảnh
      metric("tcp_listen_overflows", (now["ListenOverflows"] - before["ListenOverflows"]) / secs, "per_second", %{}),
      metric("tcp_established", now["CurrEstab"], "connections", %{})
    ]
  end

  defp per_op(_total, 0), do: 0
  defp per_op(total, ops), do: total / ops

  defp metric(type, value, unit, labels),
    do: %{type: type, value: Float.round(value * 1.0, 2), unit: unit, labels: labels}
end
