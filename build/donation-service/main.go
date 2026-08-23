package main

import (
        "context"
        "database/sql"
        "encoding/json"
        "fmt"
        "log"
        "net/http"
        "net/url"
        "os"
//      "strconv"  // importa strconv, mas não usa em lugar algum. Causa erro de compilação.
        "strings"
        "time"

        "github.com/aws/aws-sdk-go-v2/aws"
        "github.com/aws/aws-sdk-go-v2/config"
        "github.com/aws/aws-sdk-go-v2/service/sqs"
        _ "github.com/jackc/pgx/v4/stdlib"
        "github.com/joho/godotenv"
        "github.com/prometheus/client_golang/prometheus"
        "github.com/prometheus/client_golang/prometheus/promhttp"
        "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
        "go.opentelemetry.io/otel"
        "go.opentelemetry.io/otel/attribute"
        "go.opentelemetry.io/otel/codes"
        "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
        "go.opentelemetry.io/otel/propagation"
        "go.opentelemetry.io/otel/sdk/resource"
        sdktrace "go.opentelemetry.io/otel/sdk/trace"
        oteltrace "go.opentelemetry.io/otel/trace"
)

type Donation struct {
        ID        int       `json:"id"`
        NgoID     int       `json:"ngo_id"`
        Amount    float64   `json:"amount"`
        DonorName string    `json:"donor_name"`
        Status    string    `json:"status"`
        CreatedAt time.Time `json:"created_at"`
}

type App struct {
        DB          *sql.DB
        DBName      string
        SqsSvc      *sqs.Client
        SqsQueueURL string
}

type statusRecorder struct {
        http.ResponseWriter
        status int
        detail string // complemento da linha de log, preenchido pelo handler (ex.: valor e doador)
}

func (r *statusRecorder) WriteHeader(status int) {
        r.status = status
        r.ResponseWriter.WriteHeader(status)
}

func loggingMiddleware(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
                next.ServeHTTP(rec, r)
                if r.URL.Path != "/health" && r.URL.Path != "/metrics" {
                        // trace_id correlaciona a linha de log com o trace no Tempo; fica vazio quando o tracing está desativado
                        traceRef := ""
                        if sc := oteltrace.SpanContextFromContext(r.Context()); sc.IsValid() {
                                traceRef = " trace_id=" + sc.TraceID().String()
                        }
                        log.Printf("%s %s -> %d%s%s", r.Method, r.URL.Path, rec.status, rec.detail, traceRef)
                }
        })
}

// initTracer configura o TracerProvider global para exportar spans via OTLP.
// Retorna nil (tracing desativado) quando OTEL_EXPORTER_OTLP_ENDPOINT não está
// definida ou OTEL_SDK_DISABLED=true, pois o SDK Go não honra essas variáveis
// sozinho como fazem os SDKs com auto-instrumentação.
func initTracer(ctx context.Context) *sdktrace.TracerProvider {
        if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" || os.Getenv("OTEL_SDK_DISABLED") == "true" {
                return nil
        }

        exporter, err := otlptracehttp.New(ctx)
        if err != nil {
                log.Printf("Tracing desativado - erro ao criar o exporter OTLP: %v", err)
                return nil
        }

        tp := sdktrace.NewTracerProvider(
                sdktrace.WithBatcher(exporter),
                sdktrace.WithResource(resource.Default()), // resource.Default lê OTEL_SERVICE_NAME do ambiente
        )
        otel.SetTracerProvider(tp)
        otel.SetTextMapPropagator(propagation.TraceContext{})
        log.Println("Tracing OTLP ativado (donation-service).")
        return tp
}

func main() {
        _ = godotenv.Load()

        if tp := initTracer(context.Background()); tp != nil {
                defer func() {
                        if err := tp.Shutdown(context.Background()); err != nil {
                                log.Printf("Erro ao encerrar o tracer: %v", err)
                        }
                }()
        }

        port := os.Getenv("PORT")
        if port == "" {
                port = "8082"
        }

        dbURL := os.Getenv("DATABASE_URL")
        if dbURL == "" {
                log.Fatal("DATABASE_URL é obrigatória")
        }

        db, err := sql.Open("pgx", dbURL)
        if err != nil || db.Ping() != nil {
                log.Fatalf("Erro ao conectar ao banco de dados: %v", err)
        }
        log.Println("Conectado ao PostgreSQL (donation-service).")

        // Nome do banco extraído da DATABASE_URL - vira o nó "virtual" do Postgres
        // no service graph do Tempo (mesma convenção usada pela auto-instrumentação
        // do psycopg2 nos serviços Python: atributos db.system/db.name em span CLIENT)
        dbName := ""
        if parsed, err := url.Parse(dbURL); err == nil {
                dbName = strings.TrimPrefix(parsed.Path, "/")
        }

        var sqsSvc *sqs.Client
        queueURL := os.Getenv("AWS_SQS_URL")
        region := os.Getenv("AWS_REGION")
        if queueURL != "" && region != "" {
                awsCfg, err := config.LoadDefaultConfig(context.Background(), config.WithRegion(region))
                if err != nil {
                        log.Fatalf("Erro ao carregar configuração AWS: %v", err)
                }
                sqsSvc = sqs.NewFromConfig(awsCfg, func(o *sqs.Options) {
                        if endpoint := os.Getenv("AWS_ENDPOINT_URL"); endpoint != "" {
                                o.BaseEndpoint = aws.String(endpoint) // permite apontar para um emulador local (ex: ElasticMQ) em vez da AWS real
                        }
                })
                log.Println("Integração com AWS SQS ativada.")
        }

        app := &App{DB: db, DBName: dbName, SqsSvc: sqsSvc, SqsQueueURL: queueURL}

        metricsRegistry := prometheus.NewRegistry()
        metricsRegistry.MustRegister(newDonationMetricsCollector(db))

        mux := http.NewServeMux()
        mux.HandleFunc("/health", app.HealthHandler)
        mux.HandleFunc("/donations", app.DonationHandler)
        mux.Handle("/metrics", promhttp.HandlerFor(metricsRegistry, promhttp.HandlerOpts{}))

        // otelhttp cria o span de servidor e injeta o contexto do trace na requisição;
        // /health e /metrics ficam de fora para não poluir o Tempo com sondas de
        // liveness/readiness e coletas do Prometheus
        handler := otelhttp.NewHandler(loggingMiddleware(mux), "http.server",
                otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/health" && r.URL.Path != "/metrics" }),
                otelhttp.WithSpanNameFormatter(func(operation string, r *http.Request) string {
                        return r.Method + " " + r.URL.Path
                }),
        )

        log.Printf("donation-service rodando na porta %s", port)
        log.Fatal(http.ListenAndServe(":"+port, handler))
}

func (a *App) HealthHandler(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(http.StatusOK)
        if _, err := w.Write([]byte(`{"status":"ok","service":"donation-service"}`)); err != nil {
                log.Printf("Erro ao escrever resposta de health: %v", err)
        }
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")

        if r.Method == http.MethodPost {
                var d Donation
                if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
                        http.Error(w, `{"error":"Payload inválido"}`, http.StatusBadRequest)
                        return
                }

                // Enriquece a linha de log da requisição com os dados da doação
                if rec, ok := w.(*statusRecorder); ok {
                        rec.detail = fmt.Sprintf(" | valor=%.2f doador=%q ngo_id=%d", d.Amount, d.DonorName, d.NgoID)
                }

                d.Status = "APPROVED"  // Simulação de gateway de pagamento

                // Span filho do INSERT com os dados de negócio da doação. SpanKind
                // Client + atributos db.system/db.name (mesma convenção da auto-
                // instrumentação do psycopg2) fazem o Tempo desenhar o edge para o
                // nó "virtual" do Postgres no service graph.
                ctx, span := otel.Tracer("donation-service").Start(r.Context(), "INSERT donations",
                        oteltrace.WithSpanKind(oteltrace.SpanKindClient),
                        oteltrace.WithAttributes(
                                attribute.String("db.system", "postgresql"),
                                attribute.String("db.name", a.DBName),
                                attribute.Int("donation.ngo_id", d.NgoID),
                                attribute.Float64("donation.amount", d.Amount),
                                attribute.String("donation.donor_name", d.DonorName),
                        ))
                err := a.DB.QueryRowContext(ctx,
                        "INSERT INTO donations (ngo_id, amount, donor_name, status) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
                        d.NgoID, d.Amount, d.DonorName, d.Status,
                ).Scan(&d.ID, &d.CreatedAt)

                if err != nil {
                        span.RecordError(err)
                        span.SetStatus(codes.Error, "erro ao salvar doação")
                        span.End()
                        log.Printf("Erro ao salvar doação: %v", err)
                        http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
                        return
                }
                span.End()

                if a.SqsSvc != nil {
                        // WithoutCancel mantém o contexto do trace vivo após a resposta ser enviada
                        go a.sendNotificationEvent(context.WithoutCancel(r.Context()), d)
                }

                w.WriteHeader(http.StatusCreated)
                if err := json.NewEncoder(w).Encode(d); err != nil {
                        log.Printf("Erro ao codificar resposta: %v", err)
                }
                return
        }

        if r.Method == http.MethodGet {
                rows, err := a.DB.QueryContext(r.Context(), "SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC")
                if err != nil {
                        http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
                        return
                }
                defer func() {
                        if err := rows.Close(); err != nil {
                                log.Printf("Erro ao fechar cursor de doações: %v", err)
                        }
                }()

                donations := []Donation{}
                for rows.Next() {
                        var d Donation
                        if err := rows.Scan(&d.ID, &d.NgoID, &d.Amount, &d.DonorName, &d.Status, &d.CreatedAt); err != nil {
                                log.Printf("Erro ao ler doação: %v", err)
                                continue
                        }
                        donations = append(donations, d)
                }

                if err := json.NewEncoder(w).Encode(donations); err != nil {
                        log.Printf("Erro ao codificar resposta: %v", err)
                }
                return
        }

        http.Error(w, `{"error":"Método não permitido"}`, http.StatusMethodNotAllowed)
}

// donationMetricsCollector consulta o total e o somatório direto no Postgres a
// cada coleta do Prometheus (em vez de manter contadores em memória), para o
// valor nunca divergir do estado real da tabela - a mesma divergência que
// motivou estas métricas quando o total vinha de um painel Grafana baseado em
// contagem de linhas de log no Loki.
type donationMetricsCollector struct {
        db            *sql.DB
        totalDesc     *prometheus.Desc
        amountSumDesc *prometheus.Desc
}

func newDonationMetricsCollector(db *sql.DB) *donationMetricsCollector {
        return &donationMetricsCollector{
                db:            db,
                totalDesc:     prometheus.NewDesc("solidarytech_donations_total", "Total de doações registradas na plataforma", nil, nil),
                amountSumDesc: prometheus.NewDesc("solidarytech_donations_amount_sum", "Soma do valor de todas as doações registradas", nil, nil),
        }
}

func (c *donationMetricsCollector) Describe(ch chan<- *prometheus.Desc) {
        ch <- c.totalDesc
        ch <- c.amountSumDesc
}

func (c *donationMetricsCollector) Collect(ch chan<- prometheus.Metric) {
        var total int64
        var amountSum float64
        if err := c.db.QueryRow("SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM donations").Scan(&total, &amountSum); err != nil {
                log.Printf("Erro ao coletar métricas de doações: %v", err)
                return
        }
        ch <- prometheus.MustNewConstMetric(c.totalDesc, prometheus.GaugeValue, float64(total))
        ch <- prometheus.MustNewConstMetric(c.amountSumDesc, prometheus.GaugeValue, amountSum)
}

func (a *App) sendNotificationEvent(ctx context.Context, d Donation) {
        // Span próprio para o despacho assíncrono do evento (fire-and-forget)
        ctx, span := otel.Tracer("donation-service").Start(ctx, "SQS SendMessage",
                oteltrace.WithSpanKind(oteltrace.SpanKindProducer))
        defer span.End()

        body, _ := json.Marshal(d)
        _, err := a.SqsSvc.SendMessage(ctx, &sqs.SendMessageInput{
                MessageBody: aws.String(string(body)),
                QueueUrl:    aws.String(a.SqsQueueURL),
        })
        if err != nil {
                span.RecordError(err)
                span.SetStatus(codes.Error, "falha ao despachar evento SQS")
                log.Printf("Falha ao despachar evento SQS: %v", err)
        }
}
