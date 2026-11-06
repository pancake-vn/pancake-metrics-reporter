# MetricsCake

MetricsCake là thư viện giúp đơn giản hoá thao tác thu thập và xuất bản metric. MetricsCake được thiết kế để hoạt động cùng với [Telemetry](https://hexdocs.pm/telemetry/readme.html). MetricsCake có 2 nhiệm vụ chính:

1. Thu thập, xử lý telemetry event và tổng hợp thành metric
2. Cho phép xuất bản metric thông qua HTTP endpoint

## Cách sử dụng

Nhiệm vụ của người sử dụng MetricsCake là 1) cung cấp mô tả về những metric muốn thu thập (gọi là metrics spec) và 2) format metric để xuất bản.

```elixir
# telemetry emit event sau khi xử lý http request
:telemetry.execute(
  [:web, :http_request, :done],
  %{latency: latency},
  %{request_path: path, status_code: status}
)

# Thu thập metric về số lượng request / s
metrics_spec = [
  Telemetry.Metrics.counter(
    "web.http_request",
    event_name: [:web, :http_request, :done],
    measurement: nil
  )
]

# Start MetricsCake server theo spec định sẵn
MetricsCake.start_link(
  # Nhiệm vụ số 1
  metrics: metrics_spec,
  # Nhiệm vụ số 2
  report_callback: fn -> 
    # Trả về kết quả metric đã format ở đây
    [] 
  end
)
```

Trong ví dụ trên, chúng ta đã sử dụng hàm [Telemetry.Metrics.counter/2](https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html#counter/2). Hàm này sẽ tạo ra 1 struct, mô tả metric chúng ta đang muốn đo lường:

```elixir
%Telemetry.Metrics.Counter{
  description: nil,
  event_name: [:web, :http_request, :done],
  keep: nil,
  measurement: nil,
  name: [:web, :http_request],
  reporter_options: [],
  tag_values: #Function<0.70336728/1 in Telemetry.Metrics.default_metric_options/0>,
  tags: [],
  unit: :unit
}
```

### Metric là gì?

Có thể hiểu metric giống như 1 hộp đen, input là các telemetry event và output là số liệu sau khi đã tổng hợp. Trong ví dụ trên, input của metric là telemetry event `[:web, :http_request, :done]`, output của metric là số event được bắn trên giây. Tất cả các logic tổng hợp, tính toán đã được abstract bởi MetricsCake. Các tham số quan trọng của metric:

- `name`: unique name để định danh cho metric
- `event_name`: telemetry event dùng làm input cho metric

Xem doc của [Telemetry.Metrics](https://hexdocs.pm/telemetry_metrics/Telemetry.Metrics.html) để tìm hiểu thêm về các options còn lại

Hiện tại, MetricsCake support 3 loại metric. Có thể truyền thêm option cho metric thông qua field `reporter_options`:

### Counter metric

Counter metric sử dụng để đếm số lượng event. Counter metric giúp ta trả lời câu hỏi về tốc độ bắn của event, ví dụ đo lường số lượng HTTP request hoặc Redis request.

Options:

- sample_rate: tỉ lệ lấy mẫu, giá trị là số nguyên từ 0 đến 1 (tradeoff giữa tính chính xác của metric và hiệu năng)

### Summary metric

Summary metric sử dụng để đưa ra số liệu dựa trên việc tổng hợp các event. Summary metric giúp ta trả lời câu hỏi về phân phối của giá trị ([distribution](https://en.wikipedia.org/wiki/Probability_distribution)), ví dụ đo lường [median](https://en.wikipedia.org/wiki/Median) và [p99](https://en.wikipedia.org/wiki/Percentile) của database query.

Options:

- metrics: các metric cần tổng hợp, mảng gồm các giá trị hợp lệ: [:median, :p95, :p99]. Mặc định: sử dụng tất cả metrics
- sample_rate: tỉ lệ lấy mẫu, giá trị là số nguyên từ 0 đến 1 (tradeoff giữa tính chính xác của metric và hiệu năng)

### Last value metric

Last value metric lưu trữ lại giá trị của event mới nhất. Last value metric giúp ta trả lời cầu hỏi về giá trị hiện tại (hoặc mới nhất) của event là bao nhiều, ví dụ đo lường số lượng connection đang ready trong pool. Thông thường, last value metric sẽ đi kèm với 1 poller function. Hàm này sẽ liên tục được gọi để tạo ra event mới, ví dụ cứ 10s gọi kiểm tra số connection trong pool 1 lần và bắn ra telemetry event.

Options:

- poller: bắt buộc. Tuple với format {interval, callback_fun}. Cứ mỗi interval ms, callback_fun sẽ được gọi và kết quả trả về sẽ được lưu lại vào giá trị của metric.

## Built-in metrics

Bật qua option `built_in_metrics` (mặc định `[:cpu, :memory, :network, :beam]`). Mỗi built-in là 1 last value metric
tên `[:pancake_metrics_reporter, :built_in, <tên>]`, poll mỗi 15s; app tự format tên khi xuất bản như các metric khác.
Phần tử là atom hoặc `{atom, opts}`:

```elixir
MetricsCake.start_link(
  metrics: metrics_spec,
  built_in_metrics: [:cpu, :memory, :beam, :network, :network_drops, :tcp, {:disk_io, mount: "/cdn-storage"}],
  report_callback: &report/0
)
```

| Built-in | Giá trị (`report.value`) | Nguồn |
|---|---|---|
| `:cpu`, `:memory`, `:beam` | `%{type, value, labels}` | `top`, `free`, BEAM |
| `:network` | `%{direction: "ingress" \| "egress", interface, value}`, byte/s | `/proc/net/dev` (trước đây `sudo iftop` eth0/eth1) |
| `:network_drops` | `%{type, value, unit, labels: %{interface}}`: `net_receive_drops`, `net_transmit_drops` (gói/s) | `/proc/net/dev` |
| `:disk_io` (`mount`, mặc định `"/"`) | `%{type, value, unit, labels: %{device}}`: `disk_{read,write}` (byte/s), `disk_{read,write}_ops` (/s), `disk_{read,write}_await` (ms), `disk_util` (%), `disk_in_flight` | `/proc/diskstats` của thiết bị mount ở `mount` |
| `:tcp` | `%{type, value, unit, labels}`: `tcp_retrans` (/s), `tcp_retrans_ratio` (% segment gửi), `tcp_listen_overflows` (/s), `tcp_established` | `/proc/net/snmp`, `/proc/net/netstat` (cả host) |

Các built-in đọc /proc lấy mẫu 2 lần cách 2s rồi tính chênh lệch (chỉ chạy trên Linux, không cần sudo). Built-in có
`unit` format chung được, ví dụ:

```elixir
%{metric: %{name: [:pancake_metrics_reporter, :built_in, m]}, report: report} when m in [:disk_io, :network_drops, :tcp] ->
  Enum.map(report.value || [], &%{name: "myapp_" <> &1.type, value: &1.value, unit: &1.unit, labels: &1.labels})
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `pancake_metrics_reporter` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pancake_metrics_reporter, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/pancake_metrics_reporter>.

