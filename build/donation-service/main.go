package main

import (
        "database/sql"
        "encoding/json"
        "fmt"
        "log"
        "net/http"
        "os"
//      "strconv"  // importa strconv, mas não usa em lugar algum. Causa erro de compilação.
        "time"

        "github.com/aws/aws-sdk-go/aws"
        "github.com/aws/aws-sdk-go/aws/session"
        "github.com/aws/aws-sdk-go/service/sqs"
        _ "github.com/jackc/pgx/v4/stdlib"
        "github.com/joho/godotenv"
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
        SqsSvc      *sqs.SQS
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
                if r.URL.Path != "/health" {
                        log.Printf("%s %s -> %d%s", r.Method, r.URL.Path, rec.status, rec.detail)
                }
        })
}

func main() {
        _ = godotenv.Load()

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

        var sqsSvc *sqs.SQS
        queueURL := os.Getenv("AWS_SQS_URL")
        region := os.Getenv("AWS_REGION")
        if queueURL != "" && region != "" {
        cfg := &aws.Config{Region: aws.String(region)}
        if endpoint := os.Getenv("AWS_ENDPOINT_URL"); endpoint != "" {
            cfg.Endpoint = aws.String(endpoint) // permite apontar para um emulador local (ex: ElasticMQ) em vez da AWS real
        }
        sess, _ := session.NewSession(cfg)
                sqsSvc = sqs.New(sess)
                log.Println("Integração com AWS SQS ativada.")
        }

        app := &App{DB: db, SqsSvc: sqsSvc, SqsQueueURL: queueURL}

        mux := http.NewServeMux()
        mux.HandleFunc("/health", app.HealthHandler)
        mux.HandleFunc("/donations", app.DonationHandler)

        log.Printf("donation-service rodando na porta %s", port)
        log.Fatal(http.ListenAndServe(":"+port, loggingMiddleware(mux)))
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
                err := a.DB.QueryRow(
                        "INSERT INTO donations (ngo_id, amount, donor_name, status) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
                        d.NgoID, d.Amount, d.DonorName, d.Status,
                ).Scan(&d.ID, &d.CreatedAt)

                if err != nil {
                        log.Printf("Erro ao salvar doação: %v", err)
                        http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
                        return
                }

                if a.SqsSvc != nil {
                        go a.sendNotificationEvent(d)
                }

                w.WriteHeader(http.StatusCreated)
                if err := json.NewEncoder(w).Encode(d); err != nil {
                        log.Printf("Erro ao codificar resposta: %v", err)
                }
                return
        }

        if r.Method == http.MethodGet {
                rows, err := a.DB.Query("SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC")
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

func (a *App) sendNotificationEvent(d Donation) {
        body, _ := json.Marshal(d)
        _, err := a.SqsSvc.SendMessage(&sqs.SendMessageInput{
                MessageBody: aws.String(string(body)),
                QueueUrl:    aws.String(a.SqsQueueURL),
        })
        if err != nil {
                log.Printf("Falha ao despachar evento SQS: %v", err)
        }
}