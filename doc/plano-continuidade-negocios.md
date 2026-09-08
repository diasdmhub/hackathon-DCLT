| [↩️ Voltar](./) |
| --- |

# Plano de Continuidade de Negócios (PCN)

> ⚠️ **_Em construção_**

Este documento formaliza, no formato de um Plano de Continuidade de Negócios, a estratégia de Disaster Recovery (DR) ativo-passivo já implementada em [`terra/`][terra] e [`terra-dr/`][terradr]. O objetivo é definir o RTO (Recovery Time Objective) e o RPO (Recovery Point Objective) da plataforma SolidaryTech, com atenção especial aos dados de doações, o ativo mais crítico do negócio.

<BR>

## Escopo e ativos cobertos

O PCN cobre a indisponibilidade total da região AWS ativa (definida em `terra/`), incluindo o cluster EKS, a instância RDS e a NLB. Os três armazenamentos de dados da plataforma têm estratégias de proteção distintas, descritas a seguir.

| Ativo | Serviço | Armazenamento | Protegido continuamente? |
| --- | --- | --- | --- |
| Doações | `donation-service` | RDS PostgreSQL (`sol_db`) | Sim, via read replica cross-region sempre-vivo |
| Cadastro de ONGs | `ngo-service` | RDS PostgreSQL (`sol_db`, mesma instância) | Sim, mesmo replica acima |
| Voluntários | `volunteer-service` | DynamoDB (`SolidaryTechVolunteers`) | Sim, via Global Tables (réplica sempre ativa) |
| Eventos assíncronos de doação | `donation-service` → SQS | Fila SQS | Não. Ver "O que não é coberto" abaixo |

O `donation-service` é o **hot path** da plataforma (ver `README.md`) e é tratado como prioridade nas metas de recuperação abaixo. Como `ngo-service` e `donation-service` compartilham a mesma instância RDS, a recuperação de um implica a recuperação do outro.

<BR>

## Estratégia de recuperação (resumo)

A estratégia é ativo-passivo entre duas regiões AWS, com `enable_dr = true` e `manage_dns = true` em `terra/`:

1. **Dados**: `terra/` mantém um **read replica cross-region sempre-vivo** do Postgres (`module.rds_dr_replica`), em sincronia contínua com a instância ativa (lag tipicamente de segundos, não minutos) - substituiu um desenho anterior baseado em replicação de backups automatizados, que tinha um RPO limitado pela frequência da replicação. A tabela DynamoDB de voluntários vira uma Global Table (v2), com réplica sempre ativa na região passiva. Nenhum dos dois exige ação manual em operação normal.
2. **Compute**: o ambiente passivo (VPC, EKS, NLB, observabilidade) normalmente não existe (_state_ vazio em `terra-dr/`). Ativá-lo significa promover o replica sempre-vivo em `terra/` (`var.promote_dr_db = true`, uma operação in-place e rápida, não uma restauração) e provisionar o restante do zero.
3. **Roteamento**: com `manage_dns = true`, um health check do Route53 decide o failover de DNS automaticamente entre o registro `PRIMARY` (ativo) e `SECONDARY` (passivo), com TTL de 30s.
    - Verificação na porta 8082, `/health` do `donation-service`
    - Intervalo de 30s e 3 falhas consecutivas

O runbook completo de ativação e failback está em [`doc/roteiro-dr-ativacao.md`][roteirodr]; este documento traduz esses passos em metas de tempo e ponto de recuperação.

<BR>

## RPO (Recovery Point Objective)

| Dado | Mecanismo | RPO estimado | Observação |
| --- | --- | --- | --- |
| **Doações** (`sol_db`, tabela `donations`) | Read replica cross-region sempre-vivo do RDS (`module.rds_dr_replica`) | **Segundos** | A AWS não publica um SLA formal para o `ReplicaLag`; é replicação assíncrona contínua, não um snapshot agendado. Deve ser validado empiricamente (ver "Testes" abaixo) antes de ser tratado como um número contratual |
| **ONGs** (`sol_db`, tabela `ngos`) | _Mesmo mecanismo acima_ | _Mesmo RPO das doações_ | Compartilha a instância física com `donations` |
| **Voluntários** (DynamoDB) | Global Tables (replicação assíncrona nativa) | **Segundos** | Tipicamente sub-segundo a poucos segundos de defasagem entre réplicas |
| **Eventos de doação em trânsito na fila SQS** | Nenhum (fila recriada vazia em `terra-dr/`) | **Total** (evento perdido) | Aceitável: a doação já foi persistida no RDS antes da publicação em SQS (código em `build/donation-service/main.go`), então nenhuma doação é perdida, apenas o evento assíncrono pós-gravação |

**RPO consolidado da plataforma (doações): segundos, tipicamente abaixo de 30s**, limitado pelo `ReplicaLag` do RDS, não pela fila SQS. A ativação (passo 2 do runbook) espera esse lag chegar perto de zero antes de promover o replica, então o RPO real da ativação em si tende a ficar abaixo desse valor de regime.

> ✅ **Validado em simulado real em 2026-09-08** (ver "Testes de continuidade" abaixo): mesmo com as escritas já congeladas no ativo, a métrica `ReplicaLag` do CloudWatch não cai monotonicamente a zero — oscila em ruído de polling entre 0-30s em regime normal, com um pico transitório observado de até 179s antes de voltar a cair para a faixa habitual. Isso não indica perda de dado real (é ruído do probe de replicação, não um backlog crescente — o valor sempre voltou a cair), mas revisa a expectativa de "segundos" para "tipicamente segundos a poucas dezenas de segundos, com picos de ruído de métrica que não devem ser confundidos com lag real crescente" — ver a nota correspondente em [`doc/roteiro-dr-ativacao.md`][roteirodr] (passo 2).

<BR>

## RTO (Recovery Time Objective)

O RTO é dominado pelo tempo de provisionar o compute do ambiente passivo, não pela detecção da falha nem pela promoção do replica em si (rápida, in-place). As fases abaixo seguem o runbook de [`doc/roteiro-dr-ativacao.md`][roteirodr]:

| Fase | Descrição | Tempo estimado | Medido (simulado 2026-09-08) | Automático? |
| --- | --- | --- | --- | --- |
| 1. Detecção da falha | Health check do Route53 (3 falhas × 30s) | ~1,5 min | ~1,5 min (consistente com a config; não cronometrado ao segundo) | Sim |
| 2. Decisão de declarar desastre | Confirmação manual de que a falha é regional, não transitória | Depende da equipe | N/A (simulado, decisão instantânea) | Não |
| 3. Confirmar `ReplicaLag` ≈ 0 e promover o replica | `terraform apply -var="promote_dr_db=true"` em `terra/` (`ModifyDBInstance` in-place - ou a variante `-target`/`-refresh=false` se a região ativa estiver mesmo inacessível, ver o runbook) | ~2 a 5 min | **~11m51s** (4m37s confirmando o `ReplicaLag`, ruidoso — ver RPO acima — + 6m47s de `apply`, dos quais 5m30s foi só o `ModifyDBInstance`) | Sim, após início manual |
| 4. `terraform apply -target=module.eks` em `terra-dr/` | Criação do cluster EKS (limitação de bootstrap, ver `terra/README.md`) | ~10 a 15 min | ~11m49s | Sim, após início manual |
| 5. `terraform apply` completo em `terra-dr/` | VPC peering até o replica promovido, NLB, node group, observabilidade, instalação do FluxCD | ~15 a 25 min | **~4m32s** (bem mais rápido que o estimado) | Sim, após início manual |
| 5.5 Fechar a rota de volta do peering (2º apply em `terra/`) | Passo não listado nesta tabela originalmente, mas necessário (ver passo 5 do runbook) | _(não estimado)_ | ~1m02s | Sim, após início manual |
| 6. Sincronização do FluxCD | `Kustomization solidarytech` aplica `kube-aws/` e os 3 microsserviços sobem saudáveis | ~2 a 5 min | ~2m26s (o `donation` precisou de 4 restarts e o `ngo` de 2 antes de estabilizar — corrida entre o pod subir e a rota de peering propagar) | Sim |
| 7. Failover de DNS | Route53 já resolve `dns_record_name` para a NLB do ambiente passivo, dentro do TTL | ~30 s (já contado na fase 1, se `manage_dns = true`) | Confirmado via `dig`/health check já resolvendo para `SECONDARY` ao fim da fase 6 | Sim, se `manage_dns = true`; manual caso contrário |

**RTO consolidado estimado (engenharia): 30 a 50 minutos.**

✅ **Medido em simulado real, 2026-09-08, a partir da decisão de ativar (fim da fase 2) até uma doação de teste real ser aceita fim-a-fim (`POST /ngos` → `POST /donations` → `POST /volunteers` → `GET /volunteers/{ngo_id}`) através do endpoint com failover de DNS já aplicado: 36m01s** — dentro da faixa estimada, mas com uma distribuição diferente da esperada: a fase 3 (confirmar lag + promover) consumiu ~12 min em vez de 2-5 min (o `ModifyDBInstance` em si já leva ~5m30s, mais lento que "operação rápida in-place" sugeria, e a métrica de lag é ruidosa - ver RPO), enquanto a fase 5 (apply completo do `terra-dr/`) foi bem mais rápida que o estimado (~4m32s vs. 15-25 min). O runbook em si só precisou de 3 correções pontuais (nomes reais dos objetos `Deployment`/`HPA`, o comando de `ReplicaLag` e uma nota sobre propagação do NLB) — ver as notas "Validado em simulado real" em [`doc/roteiro-dr-ativacao.md`][roteirodr]; nenhum passo estava incorreto na ordem ou na lógica.

Duas ressalvas importantes:

- **O failback tem um mecanismo definido, mas sem RTO medido.** Diferente de uma versão anterior deste plano, voltar para a região original hoje segue um runbook simétrico e determinístico (destruir e recriar `module.rds` como replica do novo primário, aguardar o lag zerar, promover de volta - ver "Failback" em [`doc/roteiro-dr-ativacao.md`][roteirodr]), não uma reconciliação manual de dados. Ainda assim, esse processo não passou por um simulado cronometrado, então seu RTO fica de fora do número consolidado acima, tratado como uma operação planejada.
- **A fase 2 (decisão de declarar desastre) não está automatizada de propósito.** Um failover automático de compute (sem revisão manual) poderia disparar um `terraform apply` completo em resposta a uma falha transitória, o que tem custo e risco maiores do que aguardar poucos minutos de confirmação.

<BR>

## Papéis e acionamento

| Responsabilidade | Quem |
| --- | --- |
| Confirmar que a indisponibilidade é regional (não um incidente isolado do serviço) | Plantão de SRE |
| Decidir e autorizar a ativação do ambiente passivo | Plantão de SRE, conforme critério de impacto no `donation-service` |
| Executar o runbook de ativação (`doc/roteiro-dr-ativacao.md`) | Operador com acesso à conta AWS e ao state remoto (S3/DynamoDB lock) |
| Confirmar failover de DNS e validar os 3 microsserviços saudáveis | Operador, com `flux get kustomizations` e `kubectl get pods -n solidarytech` |
| Decidir e coordenar o failback | Plantão de SRE, após a região original estar confirmada saudável |

<BR>

## Testes de continuidade (simulados)

Os valores de RTO e RPO acima eram, até 2026-09-08, estimativas de engenharia derivadas da configuração do Terraform, não medidas em um simulado real. Nessa data, um simulado completo de ativação foi executado contra as contas reais de `terra/` e `terra-dr/`, com os resultados já incorporados às seções de RPO e RTO acima. Recomendação original, com o status atualizado:

1. ~~Executar um simulado completo de ativação em `terra-dr/` (sem desligar o ambiente ativo), medindo o tempo real de cada fase da tabela de RTO.~~ **Feito em 2026-09-08** — com o ambiente ativo efetivamente com as escritas congeladas (não só "sem desligar"), reproduzindo a sequência real do runbook, não uma simulação parcial.
2. ~~Inserir uma doação de teste no ambiente ativo, aguardar o `ReplicaLag` cair a zero, ativar `terra-dr/` e confirmar que a doação de teste está presente no replica promovido.~~ **Feito de forma equivalente em 2026-09-08**: em vez de inserir a doação *antes* da ativação, o fluxo completo (`POST /ngos` → `POST /donations` → `POST /volunteers` → `GET /volunteers/{ngo_id}`) foi executado *depois* da ativação, direto contra o endpoint com DNS já em failover — validando escrita e leitura ponta-a-ponta no ambiente promovido, não só a presença de um dado pré-existente.
3. Repetir o simulado periodicamente (sugestão: a cada mudança relevante em `terra/modules/rds` ou `terra/modules/dynamo`, e ao menos uma vez por ciclo de avaliação do projeto), documentando o resultado como anexo a este PCN.
4. Ao final de cada simulado, destruir o ambiente passivo (`terraform destroy` em `terra-dr/`) para não manter custo duplicado (ver "Custos" em `terra-dr/README.md`).

> ⚠️ **Pendente após o simulado de 2026-09-08**: por decisão explícita durante a execução, o ambiente passivo (`terra-dr/`) foi **deixado no ar** para inspeção adicional em vez de destruído no mesmo dia (item 4 acima ainda não executado), e o ambiente ativo (`terra/`) permanece com `donation`/`ngo`/`volunteer` escalados a zero (passo 1 do runbook) — ou seja, **o tráfego real está sendo servido pelo ambiente passivo agora**, não pelo ativo. Isso é o comportamento correto pós-failover, mas significa custo duplicado (dois clusters EKS + duas NLBs) até que alguém decida: (a) fazer o failback (Parte 2 do runbook) para voltar ao normal, ou (b) rodar `terraform destroy` em `terra-dr/` e reativar `donation`/`ngo`/`volunteer` no ativo diretamente, se o failback formal não for necessário. Nenhuma das duas foi feita neste simulado.

<BR>

## Limitações conhecidas

- A fila SQS não é replicada; eventos de doação em trânsito no momento do desastre não são reprocessados. Isso é uma perda aceita, já documentada em `terra-dr/README.md`, pois a doação em si já está persistida no RDS antes da publicação.
- O estado dos Pods e do HPA não é levado ao ambiente passivo; ele sobe do zero (`minReplicas: 1`), como qualquer `terraform apply` novo.
- A promoção do replica (fase 3 do RTO) referencia a instância primária dentro do mesmo state Terraform de `terra/`. Se a região ativa estiver mesmo inacessível (não só o cluster, mas a própria API da AWS ali), a variante `-target`/`-refresh=false` documentada no runbook evita depender dessa região - mas essa variante ainda não passou por um simulado cronometrado, o que introduz incerteza na fase 3 do RTO nesse cenário específico.
- Sem `manage_dns = true`, o failover de DNS deixa de ser automático e passa a depender de um reapontamento manual do DNS externo, o que aumenta o RTO de forma não estimada aqui. Por padrão, esse recurso é ativo.

<BR>

## Referências

- [`terra/README.md`][terra], seção "Disaster Recovery (ambiente ativo-passivo)": estratégia completa e variáveis (`enable_dr`, `manage_dns`, `rds_backup_retention_period`, `dr_aws_region`).
- [`terra-dr/README.md`][terradr]: o que fica sempre ligado versus sob demanda no ambiente passivo.
- [`doc/roteiro-dr-ativacao.md`][roteirodr]: runbook de ativação e failback, passo a passo.
- [`doc/estrutura.md`][estrutura], seção "Multicloud, Segurança e Disaster Recovery (DR)".

<BR>

| [⬆️ Top](#plano-de-continuidade-de-negócios-pcn) |
| --- |

[terra]: /terra/README.md
[terradr]: /terra-dr/README.md
[roteirodr]: /doc/roteiro-dr-ativacao.md
[estrutura]: /doc/estrutura.md
