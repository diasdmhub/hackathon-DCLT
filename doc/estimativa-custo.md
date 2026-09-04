| [↩️ Voltar](./) |
| --- |

# Agosto 2026 - Estimativas de Custo para a SolidaryTech

**Data:** 2026-09-02
**Métrica:** Custos reais
**Período:** 2026-08-01 to 2026-08-31
**Contexto:** Os recursos foram temporários, ativos por algumas horas em alguns dias (~11 de 31 dias).

<BR>

## Discriminação dos custos por serviço

| Serviço | Custo Ago | Dias Ativos | Horas ativas | $/hr | Est. Mensal |
|--- | ---: | ---: | ---: | ---: | ---: |
| EC2 - Compute | $7.4441 | 11 | 264 | $0.0282 | $20.58 |
| EC2 - Other | $4.1486 | 11 | 264 | $0.0157 | $11.47 |
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

### Considerações

- **Horas ativas** = número de dias com uso x 24.
- **Estimativa mensal** = (`Total de Ago` / `horas ativas`) x `730` hrs/mês (_período padrão da AWS_).
- **Estimativa de imposto não é por hora** - A taxa é cobrada uma única vez por cobrança de fatura, não um custo contínuo. Esse valor depende do custo total no fechamento do mês.

| [⬆️ Top](#august-2026---estimativas-de-custo-para-a-solidarytech) |
| --- |