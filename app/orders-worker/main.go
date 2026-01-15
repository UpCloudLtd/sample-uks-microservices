// orders-worker/main.go
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	amqp "github.com/rabbitmq/amqp091-go"
)

type OrderMessage struct {
	OrderID  string `json:"order_id"`
	Quantity int    `json:"quantity"`
}

var (
	workerMessagesTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "orders_worker_messages_total",
			Help: "Total messages processed by the worker",
		},
		[]string{"status"}, // ok | decode_error | db_error
	)

	workerDBErrorsTotal = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "orders_worker_db_errors_total",
			Help: "Total DB errors in worker",
		},
	)
)

func init() {
	prometheus.MustRegister(workerMessagesTotal, workerDBErrorsTotal)
}

func main() {
	amqpURL := os.Getenv("RABBITMQ_URL")
	if amqpURL == "" {
		log.Fatalf(`{"event":"missing_env","env":"RABBITMQ_URL"}`)
	}

	dsn := os.Getenv("POSTGRES_DSN")
	if dsn == "" {
		log.Fatalf(`{"event":"missing_env","env":"POSTGRES_DSN"}`)
	}

	// ---- Postgres ----
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		log.Fatalf(`{"event":"postgres_open_failed","error":%q}`, err.Error())
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		log.Fatalf(`{"event":"postgres_ping_failed","error":%q}`, err.Error())
	}

	// ---- RabbitMQ ----
	conn, err := amqp.Dial(amqpURL)
	if err != nil {
		log.Fatalf(`{"event":"rabbitmq_connect_failed","error":%q}`, err.Error())
	}
	defer conn.Close()

	ch, err := conn.Channel()
	if err != nil {
		log.Fatalf(`{"event":"rabbitmq_channel_failed","error":%q}`, err.Error())
	}
	defer ch.Close()

	q, err := ch.QueueDeclare(
		"orders",
		true,  // durable
		false, // auto-delete
		false, // exclusive
		false, // no-wait
		nil,
	)
	if err != nil {
		log.Fatalf(`{"event":"rabbitmq_queue_declare_failed","error":%q}`, err.Error())
	}

	log.Printf(`{"event":"worker_started","queue":%q}`, q.Name)

	// ---- HTTP: /metrics, /healthz, /readyz on :8081 ----
	mux := http.NewServeMux()

	mux.Handle("/metrics", promhttp.Handler())

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		if err := db.PingContext(ctx); err != nil || conn.IsClosed() {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte("not-ready"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	})

	go func() {
		addr := ":8081"
		log.Printf(`{"event":"worker_metrics_listen","addr":%q}`, addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Fatalf(`{"event":"worker_http_server_failed","error":%q}`, err.Error())
		}
	}()

	// ---- Consume messages forever ----
	msgs, err := ch.Consume(
		q.Name,
		"",
		true,  // auto-ack
		false, // exclusive
		false,
		false,
		nil,
	)
	if err != nil {
		log.Fatalf(`{"event":"rabbitmq_consume_failed","error":%q}`, err.Error())
	}

	for msg := range msgs {
		handleMessage(db, msg.Body)
	}

	// We should never get here; if msgs closes, the process will exit and K8s will restart it.
	log.Printf(`{"event":"worker_msg_channel_closed"}`)
}

func handleMessage(db *sql.DB, body []byte) {
	var m OrderMessage
	m.Quantity = 1 // default quantity

	if err := json.Unmarshal(body, &m); err != nil || m.OrderID == "" {
		workerMessagesTotal.WithLabelValues("decode_error").Inc()
		log.Printf(`{"event":"order_decode_failed","body":%q,"error":%q}`, string(body), err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	_, err := db.ExecContext(
		ctx,
		`INSERT INTO orders (order_id, quantity) VALUES ($1, $2)`,
		m.OrderID,
		m.Quantity,
	)
	if err != nil {
		workerMessagesTotal.WithLabelValues("db_error").Inc()
		workerDBErrorsTotal.Inc()
		log.Printf(`{"event":"order_insert_failed","order_id":%q,"error":%q}`, m.OrderID, err.Error())
		return
	}

	workerMessagesTotal.WithLabelValues("ok").Inc()
	log.Printf(`{"event":"order_inserted","order_id":%q,"quantity":%d}`, m.OrderID, m.Quantity)
}
