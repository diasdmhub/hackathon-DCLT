module donation-service

go 1.21

require (
	github.com/aws/aws-sdk-go v1.51.10
	github.com/jackc/pgx/v4 v4.18.3
	github.com/joho/godotenv v1.5.1
)

require github.com/jmespath/go-jmespath v0.4.0 // indirect

require (
	github.com/jackc/chunkreader/v2 v2.0.1 // indirect
	github.com/jackc/pgconn v1.14.3 // indirect
	github.com/jackc/pgio v1.0.0 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgproto3/v2 v2.3.3 // indirect
	github.com/jackc/pgservicefile v0.0.0-20221227161230-091c0ba34f0a // indirect
	github.com/jackc/pgtype v1.14.0 // indirect
//	github.com/jackc/pgx/v4/stdlib v4.18.3 // indirect
	github.com/pkg/errors v0.9.1 // indirect
	golang.org/x/crypto v0.20.0 // indirect
	golang.org/x/text v0.14.0 // indirect
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