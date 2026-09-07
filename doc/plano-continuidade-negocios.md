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

**RPO consolidado da plataforma (doações): segundos**, limitado pelo `ReplicaLag` do RDS, não pela fila SQS. A ativação (passo 2 do runbook) espera esse lag chegar perto de zero antes de promover o replica, então o RPO real da ativação em si tende a ficar abaixo desse valor de regime.

<BR>

## RTO (Recovery Time Objective)

O RTO é dominado pelo tempo de provisionar o compute do ambiente passivo, não pela detecção da falha nem pela promoção do replica em si (rápida, in-place). As fases abaixo seguem o runbook de [`doc/roteiro-dr-ativacao.md`][roteirodr]:

| Fase | Descrição | Tempo estimado | Automático? |
| --- | --- | --- | --- |
| 1. Detecção da falha | Health check do Route53 (3 falhas × 30s) | ~1,5 min | Sim |
| 2. Decisão de declarar desastre | Confirmação manual de que a falha é regional, não transitória | Depende da equipe | Não |
| 3. Confirmar `ReplicaLag` ≈ 0 e promover o replica | `terraform apply -var="promote_dr_db=true"` em `terra/` (`ModifyDBInstance` in-place - ou a variante `-target`/`-refresh=false` se a região ativa estiver mesmo inacessível, ver o runbook) | ~2 a 5 min | Sim, após início manual |
| 4. `terraform apply -target=module.eks` em `terra-dr/` | Criação do cluster EKS (limitação de bootstrap, ver `terra/README.md`) | ~10 a 15 min | Sim, após início manual |
| 5. `terraform apply` completo em `terra-dr/` | VPC peering até o replica promovido, NLB, node group, observabilidade, instalação do FluxCD | ~15 a 25 min | Sim, após início manual |
| 6. Sincronização do FluxCD | `Kustomization solidarytech` aplica `kube-aws/` e os 3 microsserviços sobem saudáveis | ~2 a 5 min | Sim |
| 7. Failover de DNS | Route53 já resolve `dns_record_name` para a NLB do ambiente passivo, dentro do TTL | ~30 s (já contado na fase 1, se `manage_dns = true`) | Sim, se `manage_dns = true`; manual caso contrário |

**RTO consolidado estimado: 30 a 50 minutos**, a partir do momento em que a equipe decide ativar o ambiente passivo (fase 2), assumindo que um operador treinado executa o runbook sem intercorrências. Esse número é uma **estimativa de engenharia, não uma meta validada por um simulado real** (ver "Testes de continuidade" abaixo).

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

Os valores de RTO e RPO acima são estimativas de engenharia derivadas da configuração do Terraform, **não foram medidos em um simulado real**. Antes de tratá-los como metas contratuais, recomenda-se:

1. Executar um simulado completo de ativação em `terra-dr/` (sem desligar o ambiente ativo), medindo o tempo real de cada fase da tabela de RTO.
2. Inserir uma doação de teste no ambiente ativo, aguardar o `ReplicaLag` cair a zero, ativar `terra-dr/` e confirmar que a doação de teste está presente no replica promovido, para medir o RPO real (não apenas o estimado pela documentação da AWS).
3. Repetir o simulado periodicamente (sugestão: a cada mudança relevante em `terra/modules/rds` ou `terra/modules/dynamo`, e ao menos uma vez por ciclo de avaliação do projeto), documentando o resultado como anexo a este PCN.
4. Ao final de cada simulado, destruir o ambiente passivo (`terraform destroy` em `terra-dr/`) para não manter custo duplicado (ver "Custos" em `terra-dr/README.md`).

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
