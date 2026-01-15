package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	amqp "github.com/rabbitmq/amqp091-go"
)

type OrderRequest struct {
	OrderID string `json:"order_id"`
}

type OrderRow struct {
	OrderID   string
	CreatedAt time.Time
}

// ---- Metrics ----

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "orders_http_requests_total",
			Help: "Total HTTP requests received by orders-api",
		},
		[]string{"handler", "method", "code"},
	)

	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "orders_http_request_duration_seconds",
			Help:    "Duration of HTTP requests for orders-api",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"handler", "method"},
	)

	ordersPublishedTotal = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "orders_published_total",
			Help: "Total number of orders published to RabbitMQ",
		},
	)
	ordersPublishFailuresTotal = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "orders_publish_failures_total",
			Help: "Total number of failures publishing orders to RabbitMQ",
		},
	)
)

func init() {
	prometheus.MustRegister(
		httpRequestsTotal,
		httpRequestDuration,
		ordersPublishedTotal,
		ordersPublishFailuresTotal,
	)
}

// ---- Logging helpers ----

func logInfo(event string, fields map[string]interface{}) {
	if fields == nil {
		fields = make(map[string]interface{})
	}
	fields["event"] = event
	fields["level"] = "info"
	b, _ := json.Marshal(fields)
	log.Println(string(b))
}

func logError(event string, fields map[string]interface{}) {
	if fields == nil {
		fields = make(map[string]interface{})
	}
	fields["event"] = event
	fields["level"] = "error"
	b, _ := json.Marshal(fields)
	log.Println(string(b))
}

// ---- RabbitMQ publisher ----

type Publisher struct {
	ch   *amqp.Channel
	conn *amqp.Connection
	q    amqp.Queue
}

func newPublisher(amqpURL, queueName string) (*Publisher, error) {
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to RabbitMQ: %w", err)
	}

	ch, err := conn.Channel()
	if err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("failed to open channel: %w", err)
	}

	q, err := ch.QueueDeclare(
		queueName,
		true,  // durable
		false, // auto-delete
		false, // exclusive
		false, // no-wait
		nil,   // args
	)
	if err != nil {
		_ = ch.Close()
		_ = conn.Close()
		return nil, fmt.Errorf("failed to declare queue: %w", err)
	}

	logInfo("rabbitmq_connected", map[string]interface{}{
		"queue": queueName,
	})

	return &Publisher{
		ch:   ch,
		conn: conn,
		q:    q,
	}, nil
}

func (p *Publisher) PublishOrder(order OrderRequest) error {
	body, err := json.Marshal(order)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err = p.ch.PublishWithContext(
		ctx,
		"",       // default exchange
		p.q.Name, // routing key
		false,
		false,
		amqp.Publishing{
			ContentType: "application/json",
			Body:        body,
		},
	)
	if err != nil {
		return err
	}

	return nil
}

func (p *Publisher) Close() {
	if p.ch != nil {
		_ = p.ch.Close()
	}
	if p.conn != nil {
		_ = p.conn.Close()
	}
}

// ---- Postgres ----

var db *sql.DB

func initDB(dsn string) (*sql.DB, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("sql.Open: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("ping db: %w", err)
	}

	// Simple schema for demo
	_, err = db.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS orders (
			order_id   TEXT PRIMARY KEY,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)
	`)
	if err != nil {
		return nil, fmt.Errorf("create table: %w", err)
	}

	logInfo("postgres_connected", map[string]interface{}{
		"dsn": "redacted",
	})
	return db, nil
}

func listOrders(ctx context.Context) ([]OrderRow, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT order_id, created_at
		FROM orders
		ORDER BY created_at DESC
		LIMIT 50
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []OrderRow
	for rows.Next() {
		var o OrderRow
		if err := rows.Scan(&o.OrderID, &o.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// ---- HTML template ----

var indexTpl = template.Must(template.New("index").Parse(`
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Orders demo</title>
    <style>
      :root {
        --accent: #7B00FF;
        --accent-soft: rgba(123, 0, 255, 0.18);
        --bg: #05020A;
        --bg-elevated: #0D0817;
        --bg-elevated-soft: rgba(13, 8, 23, 0.9);
        --text-main: #F7F7FF;
        --text-muted: #A3A3C2;
        --border-subtle: rgba(255, 255, 255, 0.08);
        --radius-lg: 16px;
        --radius-md: 10px;
        --shadow-elevated: 0 18px 45px rgba(0, 0, 0, 0.65);
      }

      * {
        box-sizing: border-box;
      }

      body {
        margin: 0;
        min-height: 100vh;
        font-family: Arial, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background:
          radial-gradient(circle at top left, rgba(123, 0, 255, 0.35), transparent 55%),
          radial-gradient(circle at bottom right, rgba(0, 0, 0, 0.85), #000000);
        color: var(--text-main);
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 2.5rem 1.5rem;
      }

      .page-shell {
        width: 100%;
        max-width: 960px;
        background: linear-gradient(135deg, rgba(123, 0, 255, 0.27), rgba(0, 0, 0, 0.96));
        border-radius: 24px;
        padding: 1px; /* gradient border trick */
        box-shadow: var(--shadow-elevated);
      }

      .page-inner {
        background: radial-gradient(circle at top, var(--bg-elevated-soft), #05020F);
        border-radius: 24px;
        padding: 2.5rem 2rem 2.75rem;
      }

      @media (max-width: 640px) {
        .page-inner {
          padding: 2rem 1.5rem 2.25rem;
        }
      }

      .page-header {
        text-align: center;
        margin-bottom: 2.25rem;
      }

      .page-kicker {
        font-size: 0.75rem;
        letter-spacing: 0.18em;
        text-transform: uppercase;
        color: var(--text-muted);
        margin-bottom: 0.5rem;
      }

      h1 {
        font-size: 2rem;
        margin: 0;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        text-align: center;
        background: linear-gradient(120deg, #ffffff, #d5b7ff, var(--accent));
        -webkit-background-clip: text;
        background-clip: text;
        color: transparent;
      }

      .header-sub {
        margin-top: 0.75rem;
        font-size: 0.95rem;
        color: var(--text-muted);
      }

      /* Form section */
      .card {
        background: radial-gradient(circle at top left, rgba(123, 0, 255, 0.22), transparent 60%), var(--bg-elevated);
        border-radius: var(--radius-lg);
        border: 1px solid var(--border-subtle);
        padding: 1.5rem 1.75rem 1.75rem;
        margin-bottom: 2rem;
      }

      @media (max-width: 640px) {
        .card {
          padding: 1.25rem 1.25rem 1.5rem;
        }
      }

      .card-title {
        font-size: 0.95rem;
        font-weight: 600;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--text-muted);
        margin-bottom: 1.25rem;
        text-align: center;
      }

      form#order-form {
        margin: 0;
      }

      .field-label {
        display: block;
        margin: 0 0 0.5rem;
        font-size: 0.85rem;
        color: var(--text-muted);
        text-align: center;
      }

      .input-row {
        display: flex;
        align-items: stretch;
        justify-content: center;
        gap: 0.75rem;
        flex-wrap: wrap;
      }

      #order_id {
        min-width: 260px;
        max-width: 360px;
        width: 100%;
        padding: 0.75rem 1rem;
        border-radius: var(--radius-md);
        border: 1px solid rgba(255, 255, 255, 0.12);
        background: rgba(3, 2, 15, 0.9);
        color: var(--text-main);
        font-size: 0.95rem;
        outline: none;
        transition: border-color 0.15s ease, box-shadow 0.15s ease, background 0.15s ease;
      }

      #order_id::placeholder {
        color: rgba(163, 163, 194, 0.85);
      }

      #order_id:focus {
        border-color: var(--accent);
        box-shadow: 0 0 0 1px rgba(123, 0, 255, 0.6);
        background: rgba(6, 3, 25, 0.98);
      }

      button[type="submit"] {
        padding: 0.8rem 1.5rem;
        border-radius: var(--radius-md);
        border: none;
        background: linear-gradient(135deg, var(--accent), #9f4dff);
        color: #ffffff;
        font-weight: 600;
        font-size: 0.95rem;
        cursor: pointer;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        white-space: nowrap;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 0.35rem;
        box-shadow: 0 12px 30px rgba(123, 0, 255, 0.45);
        transition: transform 0.12s ease, box-shadow 0.12s ease, opacity 0.12s ease;
      }

      button[type="submit"]:hover {
        transform: translateY(-1px);
        box-shadow: 0 16px 40px rgba(123, 0, 255, 0.6);
        opacity: 0.95;
      }

      button[type="submit"]:active {
        transform: translateY(0);
        box-shadow: 0 6px 18px rgba(123, 0, 255, 0.5);
        opacity: 0.9;
      }

      .status-line {
        margin-top: 1rem;
        min-height: 1.25rem;
        font-size: 0.85rem;
        text-align: center;
        color: var(--text-muted);
      }

      .status-line--active {
        color: #e6d2ff;
      }

      .status-line--error {
        color: #ff8796;
      }

      /* Orders table */
      .orders-section {
        text-align: center;
      }

      .orders-title {
        margin: 0 0 0.5rem;
        font-size: 1.1rem;
        font-weight: 600;
        letter-spacing: 0.16em;
        text-transform: uppercase;
        color: var(--text-muted);
      }

      .orders-subtitle {
        font-size: 0.85rem;
        color: var(--text-muted);
        margin-bottom: 1.25rem;
      }

      .orders-table-wrap {
        overflow-x: auto;
        padding-bottom: 0.25rem;
      }

      table {
        border-collapse: collapse;
        margin: 0 auto;
        width: 100%;
        max-width: 100%;
        min-width: 360px;
        background: rgba(5, 4, 18, 0.92);
        border-radius: var(--radius-lg);
        overflow: hidden;
        border: 1px solid var(--border-subtle);
      }

      thead {
        background: linear-gradient(90deg, rgba(123, 0, 255, 0.7), rgba(30, 0, 72, 0.95));
      }

      th,
      td {
        padding: 0.65rem 0.9rem;
        font-size: 0.9rem;
        border-bottom: 1px solid rgba(255, 255, 255, 0.045);
        text-align: left;
      }

      th {
        font-weight: 600;
        letter-spacing: 0.12em;
        text-transform: uppercase;
        color: #f8f4ff;
        font-size: 0.8rem;
      }

      tbody tr:nth-child(even) {
        background-color: rgba(16, 12, 35, 0.95);
      }

      tbody tr:nth-child(odd) {
        background-color: rgba(6, 4, 22, 0.95);
      }

      tbody tr:hover {
        background: radial-gradient(circle at left, var(--accent-soft), transparent 60%), rgba(6, 4, 22, 0.98);
      }

      tbody td:first-child {
        font-family: "Courier New", Courier, monospace;
        font-size: 0.9rem;
        color: #f3e7ff;
      }

      tbody td:last-child {
        color: var(--text-muted);
      }

      .empty-state {
        text-align: center;
        padding: 1rem 0.75rem;
        font-size: 0.9rem;
        color: var(--text-muted);
      }
    </style>
  </head>
  <body>
    <div class="page-shell">
      <div class="page-inner">
        <header class="page-header">
          <div class="page-kicker">Orders</div>
          <h1>Orders Demo</h1>
          <p class="header-sub">Create a new order and see it appear in the latest 50 orders from Postgres.</p>
        </header>

        <section class="card">
          <div class="card-title">Create New UpCloud Order</div>

          <form id="order-form">
            <label for="order_id" class="field-label">UpCloud Order ID</label>
            <div class="input-row">
              <input
                name="order_id"
                id="order_id"
                required
                placeholder="Enter an order identifier"
              >
              <button type="submit">
                Create order
              </button>
            </div>
          </form>

          <div id="status" class="status-line"></div>
        </section>

        <section class="orders-section">
          <h2 class="orders-title">Last 50 Orders</h2>
          <p class="orders-subtitle">Latest entries loaded directly from Postgres.</p>

          <div class="orders-table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Order ID</th>
                  <th>Created at</th>
                </tr>
              </thead>
              <tbody id="orders-body">
                {{range .Orders}}
                <tr>
                  <td>{{.OrderID}}</td>
                  <td>{{.CreatedAt}}</td>
                </tr>
                {{else}}
                <tr>
                  <td colspan="2" class="empty-state">No orders yet.</td>
                </tr>
                {{end}}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </div>

    <script>
      async function postOrder(id) {
        const res = await fetch('/orders', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({order_id: id})
        });
        if (!res.ok) {
          const text = await res.text();
          throw new Error('POST /orders failed: ' + text);
        }
      }

      const statusEl = document.getElementById('status');

      function setStatus(text, mode) {
        statusEl.textContent = text || '';
        statusEl.className = 'status-line';
        if (!text) return;
        if (mode === 'error') {
          statusEl.classList.add('status-line--error');
        } else {
          statusEl.classList.add('status-line--active');
        }
      }

      document.getElementById('order-form').addEventListener('submit', async (e) => {
        e.preventDefault();
        const input = document.getElementById('order_id');
        const id = input.value.trim();
        if (!id) return;
        try {
          setStatus('Sending...');
          await postOrder(id);
          setStatus('Order accepted. Refresh in a moment to see it in the list.');
          input.value = '';
        } catch (err) {
          setStatus(err.toString(), 'error');
        }
      });
    </script>
  </body>
</html>

`))

// ---- HTTP handlers ----

func main() {
	amqpURL := os.Getenv("RABBITMQ_URL")
	if amqpURL == "" {
		logError("missing_env", map[string]interface{}{
			"env": "RABBITMQ_URL",
		})
		os.Exit(1)
	}

	postgresDSN := os.Getenv("POSTGRES_DSN")
	if postgresDSN == "" {
		logError("missing_env", map[string]interface{}{
			"env": "POSTGRES_DSN",
		})
		os.Exit(1)
	}

	var err error
	db, err = initDB(postgresDSN)
	if err != nil {
		logError("postgres_connect_failed", map[string]interface{}{
			"error": err.Error(),
		})
		os.Exit(1)
	}
	defer db.Close()

	queueName := "orders"

	pub, err := newPublisher(amqpURL, queueName)
	if err != nil {
		logError("rabbitmq_connect_failed", map[string]interface{}{
			"error": err.Error(),
		})
		os.Exit(1)
	}
	defer pub.Close()

	mux := http.NewServeMux()

	// Root HTML page
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		logAndCount(w, r, "index", func(w http.ResponseWriter) (int, error) {
			orders, err := listOrders(r.Context())
			if err != nil {
				logError("list_orders_failed", map[string]interface{}{
					"error": err.Error(),
				})
				http.Error(w, "DB error", http.StatusInternalServerError)
				return http.StatusInternalServerError, err
			}
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			if err := indexTpl.Execute(w, struct{ Orders []OrderRow }{Orders: orders}); err != nil {
				logError("template_execute_failed", map[string]interface{}{
					"error": err.Error(),
				})
				return http.StatusInternalServerError, err
			}
			return http.StatusOK, nil
		})
	})

	// /healthz – liveness
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		logAndCount(w, r, "healthz", func(w http.ResponseWriter) (int, error) {
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`ok`))
			return http.StatusOK, nil
		})
	})

	// /readyz – readiness (simple: check connection open)
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		logAndCount(w, r, "readyz", func(w http.ResponseWriter) (int, error) {
			if pub.ch == nil || pub.conn == nil || pub.conn.IsClosed() {
				err := errors.New("rabbitmq_not_ready")
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = w.Write([]byte(err.Error()))
				return http.StatusServiceUnavailable, err
			}
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`ready`))
			return http.StatusOK, nil
		})
	})

	// /orders – GET = list (JSON), POST = publish order
	mux.HandleFunc("/orders", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			logAndCount(w, r, "orders_list", func(w http.ResponseWriter) (int, error) {
				orders, err := listOrders(r.Context())
				if err != nil {
					logError("list_orders_failed", map[string]interface{}{
						"error": err.Error(),
					})
					http.Error(w, "DB error", http.StatusInternalServerError)
					return http.StatusInternalServerError, err
				}
				w.Header().Set("Content-Type", "application/json")
				if err := json.NewEncoder(w).Encode(orders); err != nil {
					return http.StatusInternalServerError, err
				}
				return http.StatusOK, nil
			})

		case http.MethodPost:
			logAndCount(w, r, "orders_create", func(w http.ResponseWriter) (int, error) {
				var req OrderRequest
				if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.OrderID == "" {
					w.WriteHeader(http.StatusBadRequest)
					_, _ = w.Write([]byte(`{"error":"invalid payload"}`))
					logError("order_invalid_payload", map[string]interface{}{
						"error": err,
					})
					return http.StatusBadRequest, err
				}

				if err := pub.PublishOrder(req); err != nil {
					ordersPublishFailuresTotal.Inc()
					w.WriteHeader(http.StatusInternalServerError)
					_, _ = w.Write([]byte(`{"error":"publish failed"}`))
					logError("order_publish_failed", map[string]interface{}{
						"order_id": req.OrderID,
						"error":    err.Error(),
					})
					return http.StatusInternalServerError, err
				}

				ordersPublishedTotal.Inc()
				logInfo("order_published", map[string]interface{}{
					"order_id": req.OrderID,
				})

				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusAccepted)
				_, _ = w.Write([]byte(`{"status":"accepted"}`))
				return http.StatusAccepted, nil
			})

		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})

	// /metrics – Prometheus
	mux.Handle("/metrics", promhttp.Handler())

	addr := ":8080"
	logInfo("orders_api_starting", map[string]interface{}{
		"addr": addr,
	})
	if err := http.ListenAndServe(addr, mux); err != nil {
		logError("http_server_failed", map[string]interface{}{
			"error": err.Error(),
		})
		os.Exit(1)
	}
}

func logAndCount(
	w http.ResponseWriter,
	r *http.Request,
	handler string,
	fn func(http.ResponseWriter) (int, error),
) {
	start := time.Now()
	code, err := fn(w)
	duration := time.Since(start).Seconds()

	httpRequestDuration.WithLabelValues(handler, r.Method).Observe(duration)
	httpRequestsTotal.WithLabelValues(handler, r.Method, fmt.Sprint(code)).Inc()

	if err != nil {
		logError("http_request_error", map[string]interface{}{
			"handler": handler,
			"method":  r.Method,
			"code":    code,
			"error":   err.Error(),
		})
	}
}
