| [↩️ Voltar](/) |
| --- |

# SLI, SLO e SLA do Donation Service

Este documento formaliza os indicadores, as metas e o compromisso de nível de serviço do `donation-service`, o _hot path_ da SolidaryTech.

<BR>

## SLI, SLO e SLA

Todos os valores se referem a uma **janela mensal de `30` dias (`720h`)**.

| Indicador | SLI (o que se mede) | SLO (meta interna) | SLA (compromisso com as ONGs) |
| --- | --- | --- | --- |
| **Erros** | % de requisições sem erro | `>= 98%` | `>= 95%` |
| **Latência** | % de requisições respondidas em até `512ms` | `>= 98%` | `>= 95%` |

**O SLA é deliberadamente mais brando que o SLO.** Se as duas metas fossem iguais, o compromisso seria violado no mesmo instante em que o _error budget_ acabasse, sem tempo para reagir. A faixa entre 95% e 98% funciona como uma zona de alerta, em que a política de congelamento de mudanças já está em vigor.

| Meta | Tolerância a falhas | Equivalência em `720h` |
| --- | --- | --- |
| SLO de `98%` | _Error budget_ de `2%` | `14,4h` de tolerância e `705,6h` de operação normal |
| SLA de `95%` | Tolerância de `5%` | `36h` de tolerância e `684h` de operação normal |

As equivalências em horas são aproximações por proporção, já que os SLIs são medidos por requisição e não por tempo.

<BR>

## Definição dos SLIs

Os SLIs vêm do _span-metrics_ do Tempo (`traces_spanmetrics_*`), consultado pelo Prometheus, e são consultados na [dashboard de Golden Metrics][dashgrafana].

| SLI | Serviços | Definição | Janela | SLO |
| --- | --- | --- | --- | --- |
| Latência p95 | Os 3 serviços | p95 do histograma `traces_spanmetrics_latency_bucket` | Seletor de período da dashboard | Não |
| Taxa de erro | Os 3 serviços | Requisições com erro sobre o total, em `traces_spanmetrics_calls_total` | Seletor de período da dashboard | Não |
| **SLO de erros** | `donation-service` | Evento "bom" é a requisição sem erro, sendo 5xx ou 4xx considerados erros | 30 dias fixos | `>= 98%` |
| **SLO de latência** | `donation-service` | Razão entre as requisições de duração até `512ms` e o total | 30 dias fixos | `>= 98%` |

Observações:

- O SLI de erros é conservador de propósito: conta também os 4xx. Vide definição abaixo em "_Escopo e medição_".
- O alerta `solidarytech-donation-error-rate` dispara quando a taxa de erro do `donation-service` passa de `2%` por `5` minutos, o mesmo limite do _error budget_ do SLO.

> O limite de `512ms` é o bucket padrão do Tempo mais próximo de `500ms`, o que evita personalizar os buckets do _metrics-generator_.

<BR>

## Escopo e medição

**Escopo:** as requisições `POST /donations` e `GET /donations` do `donation-service`. O SLA cobre a resposta à ONG ou ao doador. Não cobre o evento assíncrono publicado no SQS depois da gravação, pois a doação já está persistida no RDS nesse ponto.

### Medição:

- **Fonte principal:** o _span-metrics_ do Tempo, no Prometheus, a mesma fonte dos SLIs acima. Usar uma só fonte evita números divergentes.
- **Verificação externa (independente):** a [dashboard de Visão Externa][dashgrafana], que consulta os serviços de fora do cluster.
- **Apuração:** a cada mês, sobre a janela de 30 dias.

### Relação do SLI com o SLA:

O SLI conta os erros `4xx` e `5xx`, enquanto o SLA considera erro apenas as respostas 5xx, pois um 4xx indica requisição inválida do cliente (ver "Exclusões"). Como o SLI conta mais erros que o SLA, um SLI de erros acima de 95% garante que o SLA de erros também foi cumprido. A dashboard, portanto, é uma medida segura do SLA, ainda que mais rigorosa.

**Limitação atual:** as consultas dos painéis não filtram por rota, então incluem todas as requisições do serviço, como o `/health`. Isso tende a inflar levemente o resultado e deve ser considerado ao interpretar os números.

<BR>

## Consequências do descumprimento

A SolidaryTech não cobra das ONGs, então não há crédito financeiro. As consequências são de transparência e de proteção do serviço:

1. **Comunicação proativa.** As ONGs são informadas assim que o impacto nas doações é confirmado, com atualizações até a normalização do serviço. A comunicação ocorre quando o SLA é violado ou quando há ativação do DR.
2. **Post-mortem publicado em até 3 dias úteis.** Depois da resolução, o relatório é publicado com a causa raiz, o impacto, a linha do tempo e as ações corretivas.
3. **Congelamento de mudanças no `donation-service`.** Vale desde a quebra do SLO, conforme já previsto em `doc/estrutura.md`, e se mantém até o _error budget_ se recompor no próximo período mensal.

<BR>

## Exclusões

Não contam como indisponibilidade para o SLA:

- **Manutenção planejada**, comunicada com antecedência às ONGs, o que inclui o _failback_ planejado do DR.
- **Erros causados pelo cliente**, ou seja, respostas 4xx decorrentes de requisições inválidas.
- **Falhas fora do controle da plataforma** que a estratégia de DR não consiga contornar, como a indisponibilidade simultânea das duas regiões da AWS.
- **Ambientes de desenvolvimento e teste**, como o cluster `kubeadm-local`.
- **Falhas apenas no evento assíncrono do SQS**, desde que a doação tenha sido gravada e respondida com sucesso.

A **ativação do DR não é uma exclusão**: o tempo de recuperação de um desastre regional conta como indisponibilidade.

<BR>

## Ligação com o PCN

O [Plano de Continuidade de Negócios][pcn] define o RTO e o RPO da plataforma, e os valores são coerentes com o SLA:

| Item do PCN | Valor | Efeito no SLA |
| --- | --- | --- |
| RTO estimado | 30 a 50 minutos | Consome entre `1,4%` e `2,3%` das `36h` toleradas pelo SLA, e entre `3,5%` e `5,8%` do _error budget_ do SLO |
| Ativação medida em simulado | `36m01s` de ponta a ponta | Cerca de `1,7%` das `36h` do SLA |
| RPO das doações | Alguns segundos | O SLA não acrescenta garantia de dados além desta meta do PCN |

Portanto, um desastre regional recuperado dentro do RTO não é suficiente, sozinho, para violar o SLA. Ele pode, no entanto, consumir uma parte relevante do _error budget_ do SLO do mês.

| [⬆️ Top](#sli-slo-e-sla-do-donation-service) |
| --- |

[estrutura]: ./estrutura.md
[pcn]: ./plano-continuidade-negocios.md
[dashgrafana]: ./grafana/README.md
