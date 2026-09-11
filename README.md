# FIAP - Projeto da Fase 5 - "Hackathon" SolidaryTech

> Análise geral e implementação **opinativa** do "hackathon" da Fase 5 do curso DevOps e Arquitetura Cloud da FIAP.

Este é o ecossistema de microsserviços da SolidaryTech, que simula um ambiente corporativo distribuído para uma plataforma de doações a ONGs (_NGO em inglês_). A SolidaryTech é uma organizações sem fins lucrativos que conecta ONGs a doadores e voluntários.

O projeto foi estruturado em partes distintas e correlacionadas. Para melhor compreensão do contexto e possibilitar a replicação do ambiente na AWS, foi criado o índice abaixo.

> A proposta inicial do projeto está disponível no repositório e é apresentada ao final deste documento.

<BR>

---

### [↗️ Estrutura de disciplinas do ambiente][estrutura]
### [↗️ Arquitetura dos microserviços][arquiteturamicro]
### [↗️ Implementação inicial][implementacao]
### [↗️ Teste manual dos microserviços][testemanual]
### [↗️ Plano de Continuidade de Negócios (PCN)][pcn]
### [↗️ Roteiro de ativação/failback do DR][roteirodr]

---

<BR>

## Considerações Gerais

- De acordo com as orientações gerais do projeto "Hackathon", divulgadas na plataforma Pós-tech, o foco não está no código das aplicações, mas nas práticas de SRE, FinOps, segurança e ITSM/AIOps. Portanto, a [issue documentada no repositório original][issue3] pode prejudicar ou atrasar o andamento do projeto, pois traz uma carga desnecessária de _troubleshooting_ e não está relacionada ao projeto. Entendo que esaa é uma realidade de muitas aplicações em ambientes de produção. Contudo, para a boa continuidade do aprendizado na FIAP, acredito que o _donation-service_ deve ser revisto com parcimônia a fim de otimizar o aprendizado.
- Devido às limitações do ambiente de laboratório da AWS, principalmente no que se refere aos acessos, não foi possível implementar adequadamente toda a infraestrutura do projeto. Por isso, foi utilizado um conta privada da AWS para este projeto. No entanto, a infraestrutura do projeto é mantida em produção apenas pelo período de demonstração e testes, a fim de evitar custos elevados.
- Para o desenvolvimento, os testes ou o uso limitado, implementou-se um ambiente local de emulação da AWS utilizando, inicialmente, o Docker Compose ([`docker-compose.yaml`][dockercompose]), e, em seguida, o Kubernetes, a fim de evitar o uso do ambiente real da AWS e seus custos agregados. O ElasticMQ foi incluído para emular o SQS, e o DynamoDB Local, para a tabela do DynamoDB do _volunteer-service_.
- O Zabbix é utilizado como ferramenta central de eventos, devido à sua flexibilidade com diversas ferramentas de mercado, e devido ao seu baixo custo, pois é _open-source_. Integrados a ele, estão recursos de tratamento e automação de eventos.

<BR>

---

<details>
    <summary><b>Proposta inicial do "hackathon" da fase 5. <i>Clique para expandir</i></b></summary>

<BR>

> _Repositório original: [https://github.com/dougls/hackathon-DCLT](https://github.com/dougls/hackathon-DCLT)_

# 🚀 SolidaryTech — Hackathon Fase 5

Bem-vindo ao repositório oficial da **SolidaryTech**.

Este monorepo contém os microsserviços que compõem a plataforma da ONG e servirá como base para os desafios do Hackathon Fase 5.

O objetivo principal deste projeto é aplicar conceitos modernos de:

- SRE (Site Reliability Engineering)
- FinOps
- Multicloud
- ITSM
- Observabilidade
- Resiliência
- Kubernetes & GitOps
- Infraestrutura como Código (IaC)

---

# 🏗️ Arquitetura dos Microsserviços

O ecossistema é composto por **3 microsserviços independentes**, desenvolvidos com tecnologias diferentes para simular um ambiente corporativo distribuído.

---

## 1️⃣ NGO Service — Cadastro de ONGs

| Item | Valor |
|---|---|
| Linguagem | Python 3.9+ |
| Framework | Flask |
| Banco de Dados | PostgreSQL |
| Porta Local | `8081` |

### 📌 Descrição
Responsável pelo gerenciamento e cadastro das ONGs parceiras da plataforma.

---

## 2️⃣ Donation Service — Processamento de Doações

| Item | Valor |
|---|---|
| Linguagem | Go 1.21+ |
| Banco de Dados | PostgreSQL |
| Mensageria | AWS SQS |
| Porta Local | `8082` |

### 📌 Descrição
Este é o **Hot Path** da aplicação.

Responsável pelo processamento das doações e publicação de eventos assíncronos em filas para processamento posterior.

---

## 3️⃣ Volunteer Service — Gestão de Voluntários

| Item | Valor |
|---|---|
| Linguagem | Python 3.9+ |
| Framework | Flask |
| Banco de Dados | AWS DynamoDB |
| Porta Local | `8083` |

### 📌 Descrição
Gerencia o cadastro e inscrição de voluntários interessados em apoiar as ONGs parceiras.

Utiliza armazenamento NoSQL nativo da AWS com foco em escalabilidade.

---

# 📁 Estrutura do Repositório

```text
.
├── ngo-service/          # Código Python e scripts SQL do serviço de ONGs
├── donation-service/     # Código Go e scripts SQL do serviço de doações
└── volunteer-service/    # Código Python do serviço de voluntários
```

---

# 🚀 Executando Localmente

Antes de realizar deploy em Kubernetes e automatizações CI/CD, recomenda-se validar todo o ambiente localmente.

---

# ✅ Pré-requisitos

Certifique-se de possuir os seguintes itens instalados:

- Python 3.9+
- Go 1.21+
- Docker (opcional, mas recomendado)
- PostgreSQL
- AWS CLI configurado
- Credenciais AWS válidas

---

# 🛠️ Passo 1 — Preparação da Infraestrutura

## PostgreSQL

Crie dois bancos de dados independentes:

### Banco `ngo_db`

Execute:

```sql
ngo-service/db/init.sql
```

### Banco `donation_db`

Execute:

```sql
donation-service/db/init.sql
```

---

## AWS DynamoDB

Crie a tabela:

| Configuração | Valor |
|---|---|
| Nome da Tabela | `SolidaryTechVolunteers` |
| Partition Key | `volunteer_id` |
| Tipo | `String` |

---

## AWS SQS

Crie uma fila do tipo **Standard Queue**.

Exemplo:

```text
https://sqs.us-east-1.amazonaws.com/1234567890/solidary-donations
```

Guarde a URL da fila para utilizar nas variáveis de ambiente.

---

# ⚙️ Passo 2 — Variáveis de Ambiente

Crie um arquivo `.env` dentro de cada microsserviço.

---

## 📄 ngo-service/.env

```env
PORT=8081
DATABASE_URL="postgres://SEU_USUARIO:SUA_SENHA@localhost:5432/ngo_db"
```

---

## 📄 donation-service/.env

```env
PORT=8082
DATABASE_URL="postgres://SEU_USUARIO:SUA_SENHA@localhost:5432/donation_db"

AWS_REGION="us-east-1"
AWS_SQS_URL="SUA_URL_DA_FILA_SQS"
```

---

## 📄 volunteer-service/.env

```env
PORT=8083

AWS_REGION="us-east-1"
AWS_DYNAMODB_TABLE="SolidaryTechVolunteers"
```

---

# ▶️ Passo 3 — Inicializando os Serviços

Abra **3 terminais separados**.

---

## 🟣 Terminal 1 — NGO Service

```bash
cd ngo-service

pip install -r requirements.txt

gunicorn --bind 0.0.0.0:8081 app:app
```

---

## 🟠 Terminal 2 — Donation Service

```bash
cd donation-service

go mod tidy

go run .
```

---

## 🔵 Terminal 3 — Volunteer Service

```bash
cd volunteer-service

pip install -r requirements.txt

gunicorn --bind 0.0.0.0:8083 app:app
```

---

# 🌐 Portas Locais

| Serviço | URL |
|---|---|
| NGO Service | `http://localhost:8081` |
| Donation Service | `http://localhost:8082` |
| Volunteer Service | `http://localhost:8083` |

---

# 🎯 Objetivos do Hackathon

O código fornecido representa apenas a base do software.

O verdadeiro desafio está na engenharia, operação e resiliência da plataforma.

---

# 📦 Conteinerização

- Criar Dockerfiles
- Otimizar imagens
- Implementar estratégias multi-stage build
- Reduzir vulnerabilidades

---

# ☁️ Infraestrutura como Código (Terraform)

Provisionar:

- Amazon EKS
- Amazon RDS
- Amazon ElastiCache
- Amazon SQS
- Amazon DynamoDB
- VPC, Subnets e Security Groups

## 💰 FinOps

Implementar:

- Tags estruturadas
- Controle de custos
- Rightsizing
- Budgets e alertas financeiros

---

# 🔄 CI/CD & GitOps

Automatizar:

- Testes
- Security Scans
- Build de imagens
- Deploy em Kubernetes

Ferramentas sugeridas:

- GitHub Actions
- ArgoCD
- FluxCD

---

# 📊 Observabilidade

Instrumentar os serviços utilizando:

- OpenTelemetry
- Distributed Tracing
- Métricas
- Logs estruturados

Ferramentas sugeridas:

- Grafana
- Prometheus
- Datadog
- New Relic

---

# 🛡️ SRE & Resiliência

Definir:

- SLIs
- SLOs
- Error Budgets
- Estratégias de Disaster Recovery
- Alertas inteligentes
- Health Checks
- Auto Healing

## 🔥 Foco Principal

O `donation-service` deve ser tratado como componente crítico da plataforma.

---

# 📚 Tecnologias Envolvidas

- Python
- Flask
- Go
- PostgreSQL
- DynamoDB
- AWS SQS
- Docker
- Kubernetes
- Terraform
- GitOps
- OpenTelemetry

---

# 🤝 Contribuição

Este projeto foi criado exclusivamente para fins educacionais e execução do Hackathon Fase 5.

Sinta-se livre para evoluir a arquitetura, melhorar a observabilidade e implementar boas práticas de engenharia de plataforma.

---

# 🏁 Boa sorte!

Bom Hackathon 🚀

Faça a diferença com a **SolidaryTech** 💙

</details>

---

<BR>

| [⬆️ Top](#fiap---hackathon-fase-5---solidarytech) |
| --- |

[estrutura]: /doc/estrutura.md
[implementacao]: /doc/roteiro-cluster-aws.md
[arquiteturamicro]: /doc/arquitetura.md
[testemanual]: /doc/teste-manual.md
[pcn]: /doc/plano-continuidade-negocios.md
[roteirodr]: /doc/roteiro-dr-ativacao.md
[issue3]: https://github.com/dougls/hackathon-DCLT/issues/3
[dockercompose]: /build/docker-compose.yaml