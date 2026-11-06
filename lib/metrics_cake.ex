defmodule MetricsCake do
  use GenServer
  alias MetricsCake.{BuiltinMetrics, TDigest}
  require Logger

  @summary_metrics [:median, :p95, :p99]
  @summary_buffer_size 1_000
  @summary_retain_window 60 * 60 * 1_000 # 60 mins
  # Khi reset summary sẽ dễ xảy ra trường hợp metric tăng đột biến, cần warmup summary để tránh hiện tượng này
  @summary_warmup_window 3 * 60 * 1_000 # 3 mins

  @last_value_measurement_field :value

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    metrics =
      Keyword.get(opts, :metrics, [])
      |> Kernel.++(built_in_metrics(opts))
      |> Enum.map(&expand_reporter_options/1)
      |> Enum.map(&enforce_measurement_on_last_value/1)

    :ets.new(:metrics_reporter_utils, [:set, :named_table, :public])
    groups = Enum.group_by(metrics, & &1.event_name)

    for {event, metrics} <- groups do
      id = {__MODULE__, event, self()}
      :telemetry.attach(id, event, &__MODULE__.handle_event/4, metrics)
      Enum.each(metrics, &init_metric/1)
    end

    adapter = start_prometheus_adapter(opts)
    {:ok, %{metrics: metrics, adapter: adapter, opts: opts}}
  end

  def terminate(_, %{metrics: metrics}) do
    groups = Enum.group_by(metrics, & &1.event_name)
    for {event, _metrics} <- groups do
      id = {__MODULE__, event, self()}
      :telemetry.detach(id)
    end
  end

  def report(), do: GenServer.call(__MODULE__, :report)

  def invoke_poller(%Telemetry.Metrics.LastValue{} = metric) do
    {_interval, func} = metric.reporter_options[:poller]
    value = func.()
    :telemetry.execute(metric.event_name, %{@last_value_measurement_field => value})
  end

  def handle_call(:report, _from, %{metrics: metrics} = state) do
    result = Enum.map(metrics, &report_metric/1)
    {:reply, result, state}
  end

  def handle_cast({:event, measurements, metadata, metrics}, state) do
    do_handle_event(measurements, metadata, metrics)
    {:noreply, state}
  end

  def handle_info({:next_summary_window, metric}, state) do
    :ets.update_element(:metrics_reporter_utils, ets_key(metric), [{3, TDigest.new()}, {5, NaiveDateTime.utc_now()}])
    :timer.send_after(@summary_warmup_window, {:rolling_summary, metric})
    {:noreply, state}
  end

  def handle_info({:rolling_summary, metric}, state) do
    [{_, _, next_t_digest, _, _}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    :ets.update_element(:metrics_reporter_utils, ets_key(metric), [{2, next_t_digest}, {3, nil}])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{adapter: pid} = state) do
    adapter = start_prometheus_adapter(state.opts)
    {:noreply, %{state | adapter: adapter}}
  end

  def handle_event(_event_name, measurements, metadata, metrics) do
    {can_update_concurrently_metrics, single_thread_update_metrics} =
      Enum.split_with(metrics, fn metric ->
        case metric do
          %Telemetry.Metrics.Counter{} -> true
          %Telemetry.Metrics.Summary{} -> false
          %Telemetry.Metrics.LastValue{} -> true
          _ -> false
        end
      end)

    Enum.each(can_update_concurrently_metrics, fn metric ->
      if keep?(metric, metadata),
        do: do_handle_event(measurements, metadata, [metric])
    end)

    # Sử dụng GenServer để đảm bảo single-thread
    Enum.each(single_thread_update_metrics, fn metric ->
      if keep?(metric, metadata),
        do: GenServer.cast(__MODULE__, {:event, measurements, metadata, [metric]})
    end)
  end

  defp start_prometheus_adapter(opts) do
    adapter =
      case __MODULE__.PrometheusAdapter.start(opts) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Process.monitor(adapter)
    adapter
  end

  defp do_handle_event(measurements, metadata, metrics) do
    Enum.each(metrics, fn metric ->
      measurement = extract_measurement(metric, measurements, metadata)
      update_metric(metric, measurement, metadata)
    end)
  end

  defp init_metric(%Telemetry.Metrics.Counter{tags: [_ | _]} = metric) do
    # Với counter có tags, thì cần tạo key tuỳ theo tag_value từ event, init bằng empty map
    true = :ets.insert_new(:metrics_reporter_utils, {ets_key(metric), %{}, System.monotonic_time()})
  end

  defp init_metric(%Telemetry.Metrics.Counter{} = metric) do
    #{key, counter, since}
    true = :ets.insert_new(:metrics_reporter_utils, {ets_key(metric), :counters.new(1, []), System.monotonic_time()})
  end

  defp init_metric(%Telemetry.Metrics.Summary{} = metric) do
    # {key, t_digest, next_t_digest, buffer, last_reset}
    true = :ets.insert_new(:metrics_reporter_utils, {ets_key(metric), TDigest.new(), nil, [], nil})
    :timer.send_interval(@summary_retain_window, self(), {:next_summary_window, metric})
  end

  defp init_metric(%Telemetry.Metrics.LastValue{} = metric) do
    #{key, value}
    true = :ets.insert_new(:metrics_reporter_utils, {ets_key(metric), nil})
    reporter_options = Map.get(metric, :reporter_options, [])
    case reporter_options[:poller] do
      {interval, _func} ->
        spawn(fn -> __MODULE__.invoke_poller(metric) end)
        :timer.apply_interval(interval, __MODULE__, :invoke_poller, [metric])

      _ -> :noop
    end
  end

  defp init_metric(_), do: :noop

  defp update_metric(%Telemetry.Metrics.Counter{tags: [_ | _]} = metric, measurement, metadata) do
    tag_value = if metric.tag_values, do: metric.tag_values.(metadata), else: Map.take(metadata, metric.tags)
    ets_key = ets_key(metric)
    [{_, counters, _}] = :ets.lookup(:metrics_reporter_utils, ets_key)
    case Map.get(counters, tag_value) do
      nil ->
        counter = :counters.new(1, [])
        :ets.update_element(:metrics_reporter_utils, ets_key, {2, Map.put(counters, tag_value, counter)})
        :counters.add(counter, 1, measurement || 1)

      counter ->
        :counters.add(counter, 1, measurement || 1)
    end
  end

  defp update_metric(%Telemetry.Metrics.Counter{} = metric, measurement, _metadata) do
    [{_, counter, _}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    count = measurement || 1
    :counters.add(counter, 1, count)
  end

  defp update_metric(%Telemetry.Metrics.Summary{} = metric, measurement, _metadata)
    when measurement != nil
  do
    [{_, t_digest, next_t_digest, buffer, _}] =
      :ets.lookup(:metrics_reporter_utils, ets_key(metric))

    buffer = [measurement | buffer]
    if length(buffer) > @summary_buffer_size do
      updated_t_digest = TDigest.update(t_digest, buffer)
      updated_next_t_digest = if next_t_digest, do: TDigest.update(next_t_digest, buffer)
      :ets.update_element(
        :metrics_reporter_utils,
        ets_key(metric),
        [{2, updated_t_digest}, {3, updated_next_t_digest}, {4, []}]
      )
    else
      :ets.update_element(:metrics_reporter_utils, ets_key(metric), {4, buffer})
    end
  end

  defp update_metric(%Telemetry.Metrics.LastValue{} = metric, measurement, _metadata) do
    if !measurement,
      do: Logger.warn("Telemetry.Metrics.LastValue received a nil measurement. Metric: #{inspect(metric, pretty: true)}")

    :ets.update_element(:metrics_reporter_utils, ets_key(metric), {2, measurement})
  end

  defp update_metric(_, _, _), do: :noop

  defp do_counter_report(counter, since, reporter_options) do
    value = :counters.get(counter, 1)
    :counters.sub(counter, 1, value)
    duration = System.convert_time_unit(
      System.monotonic_time() - since,
      :native,
      :millisecond
    )

    sample_rate = reporter_options[:sample_rate]
    value = if sample_rate, do: value / sample_rate, else: value
    per_sec = Float.round(value / (duration / 1000), 2)

    %{total: value, duration: duration, per_sec: per_sec}
  end

  defp report_metric(%Telemetry.Metrics.Counter{tags: [_ | _]} = metric) do
    [{_, counters, since}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    report = Enum.map(counters, fn {tag_value, counter} ->
      do_counter_report(counter, since, metric.reporter_options)
      |> Map.put(:tag_value, tag_value)
    end)

    :ets.update_element(:metrics_reporter_utils, ets_key(metric), {3, System.monotonic_time()})
    %{metric: metric, report: report}
  end

  defp report_metric(%Telemetry.Metrics.Counter{} = metric) do
    [{_, counter, since}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    report = do_counter_report(counter, since, metric.reporter_options)
    :ets.update_element(:metrics_reporter_utils, ets_key(metric), {3, System.monotonic_time()})

    %{metric: metric, report: report}
  end

  defp report_metric(%Telemetry.Metrics.Summary{} = metric) do
    [{_, t_digest, next_t_digest, buffer, _}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))

    # Flush everything in the buffer before report
    t_digest = TDigest.update(t_digest, buffer)
    next_t_digest = if next_t_digest, do: TDigest.update(next_t_digest, buffer)
    :ets.update_element(
      :metrics_reporter_utils,
      ets_key(metric),
      [{2, t_digest}, {3, next_t_digest}, {4, []}]
    )

    interested_metrics = Keyword.get(metric.reporter_options, :metrics, [])
    report =
      for metric <- interested_metrics, metric in @summary_metrics, into: %{} do
        value =
          case metric do
            :median -> TDigest.percentile(t_digest, 0.5)
            :p95 -> TDigest.percentile(t_digest, 0.95)
            :p99 -> TDigest.percentile(t_digest, 0.99)
          end

        {metric, value}
      end

    %{
      metric: metric,
      report: report
    }
  end

  defp report_metric(%Telemetry.Metrics.LastValue{} = metric) do
    [{_, last_value}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    %{
      metric: metric,
      report: %{value: last_value}
    }
  end

  defp report_metric(metric), do: %{metric: metric, report: nil}

  defp ets_key(%Telemetry.Metrics.Counter{name: name}), do: {:counter, name}
  defp ets_key(%Telemetry.Metrics.Summary{name: name}), do: {:summary, name}
  defp ets_key(%Telemetry.Metrics.LastValue{name: name}), do: {:last_value, name}

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key ->
        key =
          if metric.__struct__ == Telemetry.Metrics.Counter and key == nil,
          do: :__count__,
          else: key

        measurements[key]
    end
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp sample_rate(1), do: fn _ -> true end
  defp sample_rate(rate), do: fn _ -> :rand.uniform() < rate end

  defp built_in_metrics(opts) do
    built_in_metrics = Keyword.get(opts, :built_in_metrics, [:cpu, :memory, :network, :beam])
    Enum.map(built_in_metrics, &BuiltinMetrics.new/1)
  end

  defp expand_reporter_options(%{reporter_options: options} = metric) do
    if options[:sample_rate] do
      keep =
        case metric do
          %{keep: nil} -> sample_rate(options[:sample_rate])
          %{keep: func} -> fn metadata ->
            func.(metadata) && sample_rate(options[:sample_rate]).(metadata)
          end
        end

      %{metric | keep: keep}
    else
      metric
    end
  end

  defp enforce_measurement_on_last_value(%Telemetry.Metrics.LastValue{} = metric),
    do: %{metric | measurement: @last_value_measurement_field}

  defp enforce_measurement_on_last_value(metric), do: metric
end
