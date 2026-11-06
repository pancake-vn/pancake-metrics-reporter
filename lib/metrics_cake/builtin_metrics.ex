defmodule MetricsCake.BuiltinMetrics do
  alias MetricsCake.ProcStats

  # `built_in_metrics: [:cpu, {:disk_io, mount: "/cdn-storage"}, ...]`: atom hoặc {atom, opts}
  def new(metric) when is_atom(metric), do: new({metric, []})

  def new({metric, opts}) do
    Telemetry.Metrics.last_value(
      "pancake_metrics_reporter.built_in.#{metric}",
      event_name: [:pancake_metrics_reporter, :built_in, metric],
      reporter_options: [poller: {15_000, fn -> gather_builtin_metric(metric, opts) end}]
    )
  end

  # Tốc độ đọc/ghi, IOPS, await, % bận của thiết bị mount ở `mount` (mặc định "/")
  def gather_builtin_metric(:disk_io, opts), do: ProcStats.disk_io(Keyword.get(opts, :mount, "/"))
  # Gói bị drop theo interface
  def gather_builtin_metric(:network_drops, _opts), do: ProcStats.network_drops()
  # Retransmit, listen overflow, số kết nối TCP của cả host
  def gather_builtin_metric(:tcp, _opts), do: ProcStats.tcp()
  def gather_builtin_metric(metric, _opts), do: gather_builtin_metric(metric)

  def gather_builtin_metric(:cpu) do
    shell_command = ~c(top -b -n 5 -d 0.2 | awk '/load/{ LOAD=$0; next } /Cpu/{ print LOAD"\\n"$0}')
    [load_avg, cpu_utilization] =
      :os.cmd(shell_command)
      |> List.to_string()
      |> String.trim()
      |> String.split("\n")
      |> Enum.take(-2)

    metrics =
      Regex.named_captures(~r/load average: (?<min_1>[\d\.]+)[,\s]+(?<min_5>[\d\.]+)[,\s]+(?<min_15>[\d\.]+)/, load_avg)
      |> Enum.map(fn {key, value} ->
        %{
          type: "load_avg",
          value: String.to_float(value),
          labels: %{"period" => key}
        }
      end)

    [idle_perent] = Regex.run(~r/[\d\.]+(?= id)/, cpu_utilization)
    metrics_1 = [
      %{type: "cpu_utilization", value: 100 - String.to_float(idle_perent) |> Float.round(2)}
    ]

    metrics ++ metrics_1
  end

  def gather_builtin_metric(:memory) do
    shell_command = ~c(free -b | sed -n '2 p' | awk '{print $2,$3,$4,$6}')
    line =
      :os.cmd(shell_command)
      |> List.to_string()
      |> String.trim()
      |> String.split("\n")
      |> List.last()

    metrics =
      Regex.named_captures(~r/(?<total>\d+) (?<used>\d+) (?<free>\d+) (?<cache>\d+)/, line)
      |> Enum.map(fn {key, value} ->
        %{
          type: key,
          value: String.to_integer(value)
        }
      end)

    metrics ++ [%{type: "beam_vm", value: :erlang.memory(:total)}]
  end

  # Băng thông vào/ra (byte/s) theo interface, đọc /proc/net/dev. Trước đây gọi `sudo iftop` cho
  # eth0/eth1 mỗi lần poll; giữ nguyên dạng `%{direction, interface, value}` để app không phải sửa.
  def gather_builtin_metric(:network), do: ProcStats.network()

  def gather_builtin_metric(:beam) do
    metrics = [
      %{type: "active_tasks", value: :erlang.statistics(:total_active_tasks_all)}
    ]

    metrics_1 =
      case :application.get_application(:runtime_tools) do
        {:ok, :runtime_tools} ->
          # 1 second
          result = :scheduler.utilization(1)
          {_, value, _} = :proplists.lookup(:weighted, result)

          [
            %{type: "scheduler_utilization", value: value * 100}
          ]

        :undefined -> []
      end

    metrics ++ metrics_1
  end
end
