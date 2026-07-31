module donation-service

go 1.25.0

require (
	github.com/aws/aws-sdk-go-v2 v1.43.2
	github.com/aws/aws-sdk-go-v2/config v1.32.33
	github.com/aws/aws-sdk-go-v2/service/sqs v1.46.2
	github.com/jackc/pgx/v4 v4.18.3
	github.com/joho/godotenv v1.5.1
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.69.0
	go.opentelemetry.io/otel v1.44.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.44.0
	go.opentelemetry.io/otel/sdk v1.44.0
	go.opentelemetry.io/otel/trace v1.44.0
)

require (
	github.com/aws/aws-sdk-go-v2/credentials v1.19.32 // indirect
	github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.18.33 // indirect
	github.com/aws/aws-sdk-go-v2/internal/configsources v1.4.33 // indirect
	github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.7.33 // indirect
	github.com/aws/aws-sdk-go-v2/internal/v4a v1.4.34 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.14 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.13.33 // indirect
	github.com/aws/aws-sdk-go-v2/service/signin v1.5.2 // indirect
	github.com/aws/aws-sdk-go-v2/service/sso v1.33.2 // indirect
	github.com/aws/aws-sdk-go-v2/service/ssooidc v1.38.2 // indirect
	github.com/aws/aws-sdk-go-v2/service/sts v1.45.2 // indirect
	github.com/aws/smithy-go v1.27.5 // indirect
	github.com/cenkalti/backoff/v5 v5.0.3 // indirect
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/felixge/httpsnoop v1.1.0 // indirect
	github.com/go-logr/logr v1.4.4 // indirect
	github.com/go-logr/stdr v1.2.2 // indirect
	github.com/google/uuid v1.6.0 // indirect
	github.com/grpc-ecosystem/grpc-gateway/v2 v2.29.0 // indirect
	go.opentelemetry.io/auto/sdk v1.2.1 // indirect
	go.opentelemetry.io/otel/exporters/otlp/otlptrace v1.44.0 // indirect
	go.opentelemetry.io/otel/metric v1.44.0 // indirect
	go.opentelemetry.io/proto/otlp v1.11.0 // indirect
	golang.org/x/net v0.57.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	google.golang.org/genproto/googleapis/api v0.0.0-20260729162451-8efbd57d26e0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20260729162451-8efbd57d26e0 // indirect
	google.golang.org/grpc v1.83.0 // indirect
	google.golang.org/protobuf v1.36.11 // indirect
)

require (
	github.com/jackc/chunkreader/v2 v2.0.1 // indirect
	github.com/jackc/pgconn v1.14.3 // indirect
	github.com/jackc/pgio v1.0.0 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgproto3/v2 v2.3.3 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/pgtype v1.14.4 // indirect
	//	github.com/jackc/pgx/v4/stdlib v4.18.3 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/text v0.40.0 // indirect
)

// # Bug: `go mod tidy` falha - entrada inválida em `donation-service/go.mod`

// ## Descrição

// De forma similar à [issue #2][issue2] do repositório ["auth-service"][authser] (_fase // 1 DLCT_), o build do `donation-service` falha na etapa `go mod tidy` com o erro:

// ```
// go: errors parsing go.mod:
// go.mod:19:2: require github.com/jackc/pgx/v4/stdlib: version "v4.18.3" invalid: // should be v0 or v1, not v4
// ```

// <BR>

// ## Causa

// O bloco de dependências indiretas do `go.mod` contém:

// ```go
// require github.com/jackc/pgx/v4/stdlib v4.18.3 // indirect
// ```

// `github.com/jackc/pgx/v4/stdlib` não é um módulo Go independente, é um subpacote do // módulo `github.com/jackc/pgx/v4`, que já está corretamente declarado (sem `// // indirect`) mais acima no mesmo arquivo. Como o caminho não termina em `/vX`, o Go // aplica a regra de sufixo de major version e rejeita a versão `v4.18.3` informada.

// O repositório não possui `go.sum` versionado, então esse erro só aparece na primeira // vez em que o `go mod tidy`/`go build` é executado.

// <BR>

// ## Correção

// Remover ou comentar a linha `github.com/jackc/pgx/v4/stdlib v4.18.3 // indirect` do // `go.mod`. O import `_ "github.com/jackc/pgx/v4/stdlib"` em `main.go` continua // funcionando normalmente, coberto pelo require do módulo pai (`github.com/jackc/pgx/// v4`).

// <BR>

// ### _Observação relacionada_

// Após esse fix, o build ainda falha em `go build` por imports não utilizados em // `main.go` (`fmt` e `strconv`), que também precisam ser removidos ou comentados.

// > Issue post: https://github.com/dougls/hackathon-DCLT/issues/3

// [issue2]: https://github.com/FIAP-TCs/auth-service/issues/2
// [authser]: https://github.com/FIAP-TCs/auth-service
