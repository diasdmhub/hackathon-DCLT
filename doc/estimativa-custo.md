| [↩️ Voltar](./) |
| --- |

# Estimativas de Custo Mensal para a SolidaryTech

## Custo de Agosto/2026

- **Data:** 2026-09-02
- **Métrica:** Custos reais
- **Período:** 2026-08-01 to 2026-08-31
- **Contexto:** Os recursos foram temporários, ativos por algumas horas em alguns dias (~11 de 31 dias).

<BR>

### Somente o Ambiente Principal

| Serviço | Custo Ago | Dias Ativos | Horas ativas | $/hr | Est. Mensal |
|--- | ---: | ---: | ---: | ---: | ---: |
| EC2 - Compute | $7.4441 | 11 | 264 | $0.0282 | $20.58 |
| EC2 - Outros | $4.1486 | 11 | 264 | $0.0157 | $11.47 |
| EKS | $3.9762 | 11 | 264 | $0.0151 | $10.99 |
| Elastic Load Balancing | $3.6909 | 9 | 216 | $0.0171 | $12.47 |
| Tax | $2.6500 | 1 | 24 | $0.1104 | $2.65 |
| VPC | $1.1246 | 11 | 264 | $0.0043 | $3.11 |
| RDS | $0.7891 | 10 | 240 | $0.0033 | $2.40 |
| S3 | $0.0028 | 13 | 312 | ~$0.0000 | $0.01 |
| DynamoDB | $0.0003 | 11 | 264 | ~$0.0000 | $0.00 |
| Route 53 | $0.0002 | 1 | 24 | ~$0.0000 | $0.01 |
| Secrets Manager | ~$0.0000 | 2 | 48 | ~$0.0000 | $0.00 |
| **TOTAL** | **$23.83** | | | | **$63.69** |

**Custo estimado mensal excluindo os impostos: `~$61.05/mês`** (_se os recursos estiverem ativos continuamente_).

<BR>

## Projeção de Setembro/2026

- **Data:** 2026-09-15
- **Métrica:** Custos estimados
- **Período:** 2026-09-01 to 2026-09-30
- **Contexto:** Os recursos foram temporários, ativos por algumas horas em alguns dias (~3 de 30 dias).

<BR>

### Ambiente Principal e Passivo Ativados

| Serviço | Região | Méd Diária ($) | Est. Mensal ($) | Dias Obs |
| --- | :---: | ---: | ---: | ---: |
| EC2 - Compute | us-east-1 | $1.0085 | $30.25 | 3 |
| EKS | us-east-1 | $0.5325 | $15.98 | 3 |
| EC2 - Outros | us-east-1 | $0.4757 | $14.27 | 3 |
| EC2 - Outros | us-west-2 | $0.4406 | $13.22 | 1 |
| EC2 - Compute | us-west-2 | $0.2511 | $7.53 | 1 |
| EKS | us-west-2 | $0.1392 | $4.18 | 1 |
| Elastic Load Balancing | us-east-1 | $0.1202 | $3.61 | 3 |
| RDS | us-east-1 | $0.1164 | $3.49 | 3 |
| VPC | us-east-1 | $0.0791 | $2.37 | 3 |
| Elastic Load Balancing | us-west-2 | $0.0450 | $1.35 | 1 |
| Cost Explorer | us-east-1 | $0.0300 | $0.90 | 1 |
| VPC | us-west-2 | $0.0210 | $0.63 | 1 |
| RDS | us-west-2 | $0.0140 | $0.42 | 3 |
| S3 | us-east-1 | $0.0005 | $0.02 | 3 |
| DynamoDB, Secrets Manager, S3 (us-west-2) | Ambos | ~$0.00 | ~$0.00 | — |
| TOTAL | | |  **$98.22**  | |

<BR>

## Considerações

- **`EC2 - Outros`** englobam conectividade, volumes EBS, NAT Gateways e outros custos adjacentes ao EC2, não somente as instâncias computacionais.
- **Essa projeções assumem o uso contínuo por cerca de 30 dias mensais.**
- **Horas ativas** = número de dias com uso x 24.
- **Estimativa mensal** = (`Total de Ago` / `horas ativas`) x `730` hrs/mês (_período padrão da AWS_).
- **Estimativa de imposto não é por hora** - A taxa é cobrada uma única vez por cobrança de fatura, não um custo contínuo. Esse valor depende do custo total no fechamento do mês.
- **Os dados avaliados para a região `us-west-2` são escassos**, pois a ela foi utilizada por pouco tempo, principalmente devido a sua natureza passiva, semi-ativada, para o projeto.

| [⬆️ Top](#estimativas-de-custo-mensal-para-a-solidarytech) |
| --- |