| [↩️ Voltar](./) |
| --- |

# Plano de Continuidade de Negócios (PCN)

> ⚠️ **_Em construção_**

Este documento formaliza, no formato de um Plano de Continuidade de Negócios, a estratégia de Disaster Recovery (DR) ativo-passivo já implementada em [`terra/`][terra] e [`terra-dr/`][terradr]. O objetivo é definir o RTO (Recovery Time Objective) e o RPO (Recovery Point Objective) da plataforma SolidaryTech, com atenção especial aos dados de doações, o ativo mais crítico do negócio.

<BR>

## Escopo e ativos cobertos

O PCN cobre a indisponibilidade total da região AWS ativa (a região de `terra/`), incluindo o cluster EKS, a instância RDS e a NLB. Os três armazenamentos de dados da plataforma têm estratégias de proteção distintas, descritas a seguir.

| Ativo | Serviço | Armazenamento | Protegido continuamente? |
| --- | --- | --- | --- |
| Doações | `donation-service` | RDS PostgreSQL (`sol_db`) | Sim, via backup automatizado replicado entre regiões |
| Cadastro de ONGs | `ngo-service` | RDS PostgreSQL (`sol_db`, mesma instância) | Sim, mesma replicação acima |
| Voluntários | `volunteer-service` | DynamoDB (`SolidaryTechVolunteers`) | Sim, via Global Tables (réplica sempre ativa) |
| Eventos assíncronos de doação | `donation-service` → SQS | Fila SQS | Não. Ver "O que não é coberto" abaixo |

O `donation-service` é o **hot path** da plataforma (ver `README.md` e `CLAUDE.md`) e é tratado como prioridade nas metas de recuperação abaixo. Como `ngo-service` e `donation-service` compartilham a mesma instância RDS (`sol_db`, ver a nota sobre o `Dockerfile-psql`/`init.sql` combinado em `CLAUDE.md`), a recuperação de um implica a recuperação do outro.

<BR>

## Estratégia de recuperação (resumo)

A estratégia é ativo-passivo entre duas regiões AWS, com `enable_dr = true` e `manage_dns = true` em `terra/`:

1. **Dados**: os backups automatizados do RDS (`rds_backup_retention_period`, 7 dias por padrão) são replicados continuamente para a região passiva via `aws_db_instance_automated_backups_replication`. A tabela DynamoDB de voluntários vira uma Global Table (v2), com réplica sempre ativa na região passiva. Nenhum dos dois exige ação manual em operação normal.
2. **Compute**: o ambiente passivo (VPC, EKS, RDS restaurado, NLB, observabilidade) normalmente não existe (state vazio em `terra-dr/`). Ativá-lo significa restaurar o RDS a partir do backup replicado (`aws_db_instance.restored`) e provisionar o restante do zero.
3. **Roteamento**: com `manage_dns = true`, um health check do Route53 (`aws_route53_health_check.primary`, porta 8082, `/health` do `donation-service`, intervalo de 30s, 3 falhas consecutivas) decide o failover de DNS automaticamente entre o registro `PRIMARY` (ativo) e `SECONDARY` (passivo), com TTL de 30s.

O runbook completo de ativação está em [`terra-dr/README.md`][terradr]; este documento traduz esses passos em metas de tempo e ponto de recuperação.

<BR>

## RPO (Recovery Point Objective)

| Dado | Mecanismo | RPO estimado | Observação |
| --- | --- | --- | --- |
| **Doações** (`sol_db`, tabela `donations`) | Replicação contínua de backups automatizados do RDS entre regiões | **Minutos** (tipicamente até 5 minutos) | A AWS não publica um SLA formal para esse lag; é uma replicação contínua de logs de transação, não um snapshot agendado. Deve ser validado empiricamente (ver "Testes" abaixo) antes de ser tratado como um número contratual |
| **ONGs** (`sol_db`, tabela `ngos`) | Mesmo mecanismo acima (mesma instância RDS) | Mesmo RPO das doações | Compartilha a instância física com `donations` |
| **Voluntários** (DynamoDB) | Global Tables (replicação assíncrona nativa) | **Segundos** | Tipicamente sub-segundo a poucos segundos de defasagem entre réplicas |
| **Eventos de doação em trânsito na fila SQS** | Nenhum (fila recriada vazia em `terra-dr/`) | **Total** (evento perdido) | Aceitável: a doação já foi persistida no RDS antes da publicação em SQS (ver `build/donation-service/main.go`), então nenhuma doação é perdida, apenas o evento assíncrono pós-gravação |

**RPO consolidado da plataforma (doações): minutos**, limitado pela replicação de backups do RDS, não pela fila SQS.

<BR>

## RTO (Recovery Time Objective)

O RTO é dominado pelo tempo de ativação do ambiente passivo, não pela detecção da falha. As fases abaixo seguem o runbook de [`terra-dr/README.md`][terradr]:

| Fase | Descrição | Tempo estimado | Automático? |
| --- | --- | --- | --- |
| 1. Detecção da falha | Health check do Route53 (3 falhas × 30s) | ~1,5 min | Sim |
| 2. Decisão de declarar desastre | Confirmação humana de que a falha é regional, não transitória | Depende da equipe (não estimado aqui) | Não |
| 3. Localizar o backup replicado mais recente | Consulta manual via AWS CLI (`describe-db-instance-automated-backups`) | ~5 min | Não |
| 4. `terraform apply -target=module.eks` | Criação do cluster EKS (limitação de bootstrap, ver `terra/README.md`) | ~10 a 15 min | Sim, após início manual |
| 5. `terraform apply` completo | Restauração do RDS a partir do backup, NLB, node group, observabilidade, instalação do FluxCD | ~15 a 25 min | Sim, após início manual |
| 6. Sincronização do FluxCD | `Kustomization solidarytech` aplica `kube-aws/` e os 3 microsserviços sobem saudáveis | ~2 a 5 min | Sim |
| 7. Failover de DNS | Route53 já resolve `dns_record_name` para a NLB do ambiente passivo, dentro do TTL | ~30 s (já contado na fase 1, se `manage_dns = true`) | Sim, se `manage_dns = true`; manual caso contrário |

**RTO consolidado estimado: 45 a 75 minutos**, a partir do momento em que a equipe decide ativar o ambiente passivo (fase 2), assumindo que um operador treinado executa o runbook sem intercorrências. Esse número é uma **estimativa de engenharia, não uma meta validada por um simulado real** (ver "Testes de continuidade" abaixo).

Duas ressalvas importantes:

- **Failback não tem RTO definido.** Voltar para a região original exige reconciliação manual dos dados gravados no ambiente passivo durante a janela de failover (dump/restore do RDS ou promoção do passivo a fonte de verdade), sem mecanismo automático. Esse processo é tratado como uma operação planejada, fora do RTO de contingência.
- **A fase 2 (decisão de declarar desastre) não está automatizada de propósito.** Um failover automático de compute (sem revisão humana) poderia disparar uma restauração de RDS e um `terraform apply` completo em resposta a uma falha transitória, o que tem custo e risco maiores do que aguardar poucos minutos de confirmação.

<BR>

## Papéis e acionamento

| Responsabilidade | Quem |
| --- | --- |
| Confirmar que a indisponibilidade é regional (não um incidente isolado do serviço) | Plantão de SRE |
| Decidir e autorizar a ativação do ambiente passivo | Plantão de SRE, conforme critério de impacto no `donation-service` (hot path) |
| Executar o runbook de ativação (`terra-dr/README.md`) | Operador com acesso à conta AWS e ao state remoto (S3/DynamoDB lock) |
| Confirmar failover de DNS e validar os 3 microsserviços saudáveis | Operador, com `flux get kustomizations` e `kubectl get pods -n solidarytech` |
| Decidir e coordenar o failback | Plantão de SRE, após a região original estar confirmada saudável |

<BR>

## Testes de continuidade (simulados)

Os valores de RTO e RPO acima são estimativas de engenharia derivadas da configuração do Terraform, **não foram medidos em um simulado real**. Antes de tratá-los como metas contratuais, recomenda-se:

1. Executar um simulado completo de ativação em `terra-dr/` (sem desligar o ambiente ativo), medindo o tempo real de cada fase da tabela de RTO.
2. Inserir uma doação de teste no ambiente ativo, aguardar a janela de replicação, ativar `terra-dr/` e confirmar em qual ponto no tempo os dados restaurados param, para medir o RPO real (não apenas o estimado pela documentação da AWS).
3. Repetir o simulado periodicamente (sugestão: a cada mudança relevante em `terra/modules/rds` ou `terra/modules/dynamo`, e ao menos uma vez por ciclo de avaliação do curso/projeto), documentando o resultado como anexo a este PCN.
4. Ao final de cada simulado, destruir o ambiente passivo (`terraform destroy` em `terra-dr/`) para não manter custo duplicado (ver "Custos" em `terra-dr/README.md`).

<BR>

## Limitações conhecidas

- A fila SQS não é replicada; eventos de doação em trânsito no momento do desastre não são reprocessados (perda aceita, já documentada em `terra-dr/README.md`, pois a doação em si já está persistida no RDS antes da publicação).
- O estado dos Pods e do HPA não é levado ao ambiente passivo; ele sobe do zero (`minReplicas: 1`), como qualquer `terraform apply` novo.
- A busca do ARN do backup replicado mais recente é uma etapa manual (não há um data source Terraform estável para isso hoje), o que introduz variabilidade humana na fase 3 do RTO.
- Sem `manage_dns = true`, o failover de DNS deixa de ser automático e passa a depender de um reponte manual do DNS externo, o que aumenta o RTO de forma não estimada aqui.

<BR>

## Referências

- [`terra/README.md`][terra], seção "Disaster Recovery (ambiente ativo-passivo)": estratégia completa e variáveis (`enable_dr`, `manage_dns`, `rds_backup_retention_period`, `dr_aws_region`).
- [`terra-dr/README.md`][terradr]: runbook de ativação e failback, passo a passo.
- [`doc/estrutura.md`][estrutura], seção "Multicloud, Segurança e Disaster Recovery (DR)".

<BR>

| [⬆️ Top](#plano-de-continuidade-de-negócios-pcn) |
| --- |

[terra]: /terra/README.md
[terradr]: /terra-dr/README.md
[estrutura]: /doc/estrutura.md
