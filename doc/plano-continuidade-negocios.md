| [↩️ Voltar](./) |
| --- |

# Plano de Continuidade de Negócios (PCN)

Este documento formaliza, por meio de um Plano de Continuidade de Negócios, a estratégia de Disaster Recovery (DR) "ativo-passivo" já implementada em [`terra/`][terra] e [`terra-dr/`][terradr] conforme definido no repositório Git. Seu objetivo é definir o RTO (Recovery Time Objective) e o RPO (Recovery Point Objective) da plataforma SolidaryTech, dedicando atenção especial aos dados de doações, que são o ativo mais crítico do negócio.

<BR>

## Escopo e ativos cobertos

O PCN abrange a indisponibilidade total da região ativa da AWS (definida em `terra/`), incluindo o cluster EKS, a instância RDS e o NLB. Os três principais formas de armazenamento de dados da plataforma possuem estratégias de proteção distintas, descritas a seguir.

| Ativo | Serviço | Armazenamento | Protegido continuamente? |
| --- | --- | --- | --- |
| Doações | `donation-service` | RDS PostgreSQL (`sol_db`) | Sim, via read replica cross-region sempre-vivo |
| Cadastro de ONGs | `ngo-service` | RDS PostgreSQL (`sol_db`, mesma instância) | Sim, mesmo replica acima |
| Voluntários | `volunteer-service` | DynamoDB (`SolidaryTechVolunteers`) | Sim, via Global Tables (réplica sempre ativa) |
| Eventos assíncronos de doação | `donation-service` → SQS | Fila SQS | Não. Ver "O que não é coberto" abaixo |

O `donation-service` é o **hot path** da plataforma (_ver `README.md`_) e é tratado como prioridade nas metas de recuperação a seguir. Como o `ngo-service` e o `donation-service` compartilham a mesma instância RDS, a recuperação de um implica a recuperação do outro.

<BR>

## Estratégia de recuperação (resumo)

A estratégia é "ativo-passivo" entre duas regiões da AWS. Ela é ativada com as variáveis `enable_dr = true` e `manage_dns = true` no diretório `terra/`.

### Dados

- O diretório `terra/` inicializa o ambiente principal e mantém uma **réplica de leitura sempre ativa do Postgres** em outra região (`module.rds_dr_replica`), em sincronia contínua com a instância ativa. Nesse método, o RPO é baseado na replicação automatizada dos dados, com latência de poucos segundos.
- A tabela DynamoDB de voluntários se torna uma "Global Table", com réplica sempre ativa na região passiva. Nenhum dos dois exige ação manual durante a operação normal.

### Compute

- O ambiente passivo (VPC, EKS, NLB, observabilidade) normalmente não existe (_state_ vazio em `terra-dr/`). Ativá-lo significa promover a réplica sempre ativa em `terra/` (`var.promote_dr_db = true`), o que é uma operação _in-place_ e rápida, não uma restauração, e provisionar os demais recursos inativos.

### Roteamento

- Com `manage_dns = true`, um health check do Route53 decide automaticamente o _failover_ de DNS entre o registro `PRIMARY` (ativo) e o `SECONDARY` (passivo), com TTL de `30` segundos.
    - Verificação na porta 8082, `/health` do `donation-service`, com um intervalo de 30s e 3 falhas consecutivas.

O roteiro completo de ativação e failback está em [`doc/roteiro-dr-ativacao.md`][roteirodr]. Esse documento traduz esses passos em metas de tempo e ponto de recuperação.

<BR>

## RPO (Recovery Point Objective)

| Dado | Mecanismo | RPO estimado | Observação |
| --- | --- | --- | --- |
| **Doações** (`sol_db`, tabela `donations`) | Read replica cross-region sempre ativa do RDS (`module.rds_dr_replica`) | **Segundos** | A AWS não publica um SLA formal para o `ReplicaLag` (CloudWatch), pois se trata de uma replicação assíncrona contínua, e não de um snapshot agendado. Por isso, deve ser validado empiricamente (ver "Testes" abaixo) antes de ser tratado como um número contratual. |
| **ONGs** (`sol_db`, tabela `ngos`) | _Mesmo mecanismo acima_ | _Mesmo RPO das doações_ | Compartilha a instância física com `donations`. |
| **Voluntários** (DynamoDB) | Global Tables (_replicação assíncrona nativa_) | **Segundos** | Tipicamente, leva sub-segundo a poucos segundos de defasagem entre réplicas. |
| **Eventos de doação em trânsito na fila SQS** | Nenhum (_fila recriada vazia em `terra-dr/`_) | **Total** (_evento perdido_) | Aceitável: a doação já foi persistida no RDS antes da publicação em SQS (código em `build/donation-service/main.go`), portanto, nenhuma doação se perde, apenas o evento assíncrono pós-gravação. |

**O RPO consolidado da plataforma (doações) é de alguns segundos, tipicamente abaixo de 30s**, e é limitado pelo `ReplicaLag` (CloudWatch) do RDS, não pela fila SQS. A ativação (passo 2 do roteiro) aguarda que esse atraso se aproxime de zero para promover a réplica, portanto, o RPO real da ativação tende a ser inferiror a esse valor.

> ✅ **Foi validado** que, mesmo com as escritas já congeladas no ativo, a métrica `ReplicaLag` do CloudWatch não cai monotonicamente para zero, mas oscila com ruído de _polling_ entre 0-30s em regime normal, com possíveis picos transitórios. Isso não indica perda de dados reais, pois trata-se de ruído do _probe_ de replicação, não de um backlog crescente (o valor sempre voltou a cair). A expectativa é de "tipicamente segundos a poucas dezenas de segundos, com picos de ruído da métrica que não devem ser confundidos com um _lag_ real crescente". _Ver a nota correspondente em [`doc/roteiro-dr-ativacao.md`][roteirodr] (passo 2)_.

<BR>

## RTO (Recovery Time Objective)

O RTO é determinado pelo tempo necessário para provisionar a capacidade de processamento do ambiente passivo, não pelo tempo de detecção da falha e nem pela rápida promoção da réplica (_in-place_). As fases abaixo seguem o _runbook_ de [`doc/roteiro-dr-ativacao.md`][roteirodr].

| Fase | Descrição | Tempo estimado | Observado | Automático? |
| --- | --- | --- | --- | --- |
| 1. Detecção da falha | Health check do Route53 (3 falhas × 30s) | ~1,5 min | ~1,5 min (consistente com a config; não cronometrado ao segundo) | Sim |
| 2. Decisão de declarar desastre | Confirmação manual de que a falha é regional, não transitória | Depende da equipe | N/A (simulado, decisão instantânea) | Não |
| 3. Confirmar `ReplicaLag` ≈ 0 e promover o replica | `terraform apply -var="promote_dr_db=true"` em `terra/` (`ModifyDBInstance` in-place - ou a variante `-target`/`-refresh=false` se a região ativa estiver mesmo inacessível, ver o runbook) | ~2 a 5 min | **~11m51s** (4m37s confirmando o `ReplicaLag`, ruidoso - ver RPO acima - + 6m47s de `apply`, dos quais 5m30s foi só o `ModifyDBInstance`) | Sim, após início manual |
| 4. `terraform apply -target=module.eks` em `terra-dr/` | Criação do cluster EKS (limitação de bootstrap, ver `terra/README.md`) | ~10 a 15 min | ~11m49s | Sim, após início manual |
| 5. `terraform apply` completo em `terra-dr/` | VPC peering até o replica promovido, NLB, node group, observabilidade, instalação do FluxCD | ~15 a 25 min | **~4m32s** (bem mais rápido que o estimado) | Sim, após início manual |
| 5. Fechar a rota de volta do peering (2º apply em `terra/`) | Ver passo 5 do _runbook_ | _não estimado_ | ~1m02s | Sim, após início manual |
| 6. Sincronização do FluxCD | `Kustomization solidarytech` aplica `kube-aws/` e os 3 microsserviços sobem saudáveis | ~2 a 5 min | ~2m26s (o `donation` precisou de 4 restarts e o `ngo` de 2 antes de estabilizar - corrida entre o pod subir e a rota de peering propagar) | Sim |
| 7. Failover de DNS | Route53 já resolve `dns_record_name` para a NLB do ambiente passivo, dentro do TTL | ~30 s (já contado na fase 1, se `manage_dns = true`) | Confirmado via `dig`/health check já resolvendo para `SECONDARY` ao fim da fase 6 | Sim, se `manage_dns = true`; manual caso contrário |

**RTO consolidado estimado é de 30 a 50 minutos.**

### ✅ Simulações

- O tempo entre a decisão de ativação e a aceitação de uma doação de teste ser aceita fim-a-fim (`POST /ngos` → `POST /donations` → `POST /volunteers` → `GET /volunteers/{ngo_id}`) por meio do endpoint com failover de DNS já aplicado foi de **36m01s**. Está dentro da faixa estimada, mas com uma distribuição diferente da esperada.
- A fase 3 (confirmar lag e promover) consumiu **~12 min**, mais do que 2-5 min esperados (a operação `ModifyDBInstance` por si só já dura ~5m30s, mais lenta que a "operação rápida in-place" sugerida, e a métrica de _lag_ é variada - _ver RPO_).
- A fase 5 (apply completo do `terra-dr/`) foi bem mais rápida que o estimado (~4m32s vs. 15-25 min).
- **O Failback também foi medido em simulado** (_ver detalhes abaixo_) e não é apenas uma operação planejada.
- ⚠️ **A fase 2 (decisão de declarar desastre) não está automatizada de propósito.** Um failover automático de processamento (sem revisão manual) poderia disparar um `terraform apply` completo em resposta a uma falha transitória, o que tem custo e risco maiores do que aguardar alguns minutos para confirmação.

<BR>

## Failback

O failback completo de volta para o ambiente ativo (`terra/`) também foi simulado (congelar escritas → recriar a instância original como replica → confirmar lag e promover → repontamento de DNS → recriar a réplica sempre ativa → `terraform destroy` em `terra-dr/`).

Estas são as estimativas por fase:

| Fase do failback | Tempo medido | Observação |
| --- | --- | --- |
| Recriar a instância original como réplica do banco ativo (passo 3) | ~36 min | Inclui o diagnóstico de um bug real encontrado no meio do simulado (ver abaixo). A operação em si, já com o comando corrigido, tem uma ordem de grandeza comparável à fase seguinte. |
| Confirmar lag e promover de volta (passo 4) | ~4m22s | Consistente com a promoção medida na ativação (~5m30s) |
| Reapontamento de DNS + reativar os 3 serviços no ativo (passo 5) | ~3 min | Inclui reescalar `donation`/`ngo`/`volunteer` de volta a 1 réplica. Necessário apenas porque o "desastre" simulado foi zerado manualmente. Numa recuperação real da região, isso não seria um passo à parte. |
| Recriar a réplica sempre ativa em `terra-dr` (passo 6) | ~21 min | **A fase mais lenta de todo o ciclo de ativação e failback**. Criar uma réplica _cross-region_ do zero é mais lento que qualquer promoção _in-place_. |
| `terraform destroy` em `terra-dr/` | ~10 min | Inclui destruição do cluster EKS, NLB e VPC do ambiente passivo. |

**O achado principal é que o failback é estruturalmente mais lento que a ativação**, porque ele precisa criar **duas** réplicas _cross-region_ do zero (recriar a instância original como réplica no passo 3, e recriar a réplica sempre ativa no passo 6), enquanto a ativação usa apenas **uma** promoção _in-place_. Uma estimativa de engenharia para o failback é de aproximadamente **55 a 60 minutos**, contra os ~36 min medidos na ativação:  promoção (~5 min), DNS/serviços (~3 min), recriação da réplica original (~15-20 min), recriação da réplica sempre ativa (~21 min), _destroy_ (~10 min).

<BR>

## Papéis e acionamento

| Responsabilidade | Quem |
| --- | --- |
| Confirmar que a indisponibilidade é regional e não um incidente isolado do serviço | Plantão de SRE |
| Decidir e autorizar a ativação do ambiente passivo | Plantão de SRE, conforme critério de impacto no `donation-service` |
| Executar o _runbook_ de ativação (`doc/roteiro-dr-ativacao.md`) | Operador com acesso à conta AWS e ao _state_ remoto (S3/DynamoDB lock) |
| Confirmar a falha de failover do DNS e validar os 3 microsserviços saudáveis | Operador |
| Decidir e coordenar a reversão | Plantão de SRE, após a região original ser confirmada como saudável |

<BR>

## Testes de continuidade

As estimativas de RTO e RPO acima são estimativas derivadas da configuração do Terraform e foram medidas em simulações contra as regiões reais da AWS, definidas em `terra/` e `terra-dr/`. Os resultados foram incorporados às seções de RPO e RTO acima. 

### Recomendação

1. Repetir o simulado periodicamente
    - Sugere-se repetir a cada mudança relevante em `terra/modules/rds` ou `terra/modules/dynamo`, e ao menos uma vez por ciclo de avaliação do projeto. Documente o resultado como anexo a este PCN.
4. Ao final de cada simulação, o ambiente passivo deve ser destruído (`terraform destroy` em `terra-dr/`) para evitar custos duplicados (_ver "Custos" em `terra-dr/README.md`_).

<BR>

## Limitações conhecidas

- A fila SQS não é replicada, portanto, eventos de doação em trânsito no momento do desastre não serão reprocessados. Essa perda é aceitável e já está documentada em `terra-dr/README.md`, pois a doação já está armazenada no RDS antes da publicação.
- O estado dos Pods e do HPA não é transferido para o ambiente passivo; ele é inicializado com o valor mínimo de réplicas (`minReplicas: 1`), como em qualquer `terraform apply` novo.
- A promoção da réplica (fase 3 do RTO) faz referência à instância primária dentro do mesmo _state_ Terraform de `terra/`. Se a região ativa estiver realmente inacessível (não apenas o cluster, mas também a própria API da AWS ali), a execução variante `-target`/`-refresh=false`, documentada no _runbook_ evita a dependência dessa região. No entanto, essa variante ainda não foi submetida a um teste cronometrado, o que introduz incerteza na fase 3 do RTO nesse cenário específico.
- Sem `manage_dns = true`, o _failover_ de DNS deixa de ser automático e passa a depender de um reapontamento manual do DNS externo, aumentando o RTO de forma não estimada. Por padrão, esse recurso está ativo.

<BR>

## Referências

- [`terra/README.md`][terra], seção "Disaster Recovery (ambiente ativo-passivo)": estratégia completa e variáveis (`enable_dr`, `manage_dns`, `rds_backup_retention_period`, `dr_aws_region`).
- [`terra-dr/README.md`][terradr]: o que fica sempre ligado versus sob demanda no ambiente passivo.
- [`doc/roteiro-dr-ativacao.md`][roteirodr]: roteiro de ativação e _failback_, passo a passo.
- [`doc/estrutura.md`][estrutura], seção "Disaster Recovery (DR)".

| [⬆️ Top](#plano-de-continuidade-de-negócios-pcn) |
| --- |

[terra]: /terra/README.md
[terradr]: /terra-dr/README.md
[roteirodr]: /doc/roteiro-dr-ativacao.md
[estrutura]: /doc/estrutura.md
