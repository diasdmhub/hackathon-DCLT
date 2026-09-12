| [↩️ Voltar](./) |
| --- |

# Estrutura de disciplinas - "Hackathon" SolidaryTech

A seguir, uma descrição sucinta das disciplinas utilizadas neste projeto. Ele emprega algumas das principais práticas de DevOps, conforme descrito a seguir.

<BR>

## Docker/Podman - Containers

- Dockerfiles otimizados para o _build_ dos 3 microserviços e sua implantação no Kubernetes.
    - Os microserviços utilizam imagens reduzidas, como a `alpine`.
    - Possuem _stage build_ otimizado para reduzir artefatos quando necessário (_donation-service_).
- Há três microserviços independentes (`ngo-service`, `donation-service` e `volunteer-service`), cada um com seu próprio banco/storage (Postgres, Postgres+SQS e DynamoDB, respectivamente).
- A "Stack" está completa em `build/docker-compose.yaml` e inclui emuladores locais de nuvem, como o ElasticMQ (SQS) e o DynamoDB Local, para que não seja necessário utilizar uma conta AWS real durante o desenvolvimento e os testes.

<BR>

## CI e DevSecOps

Trata-se de um modelo no qual o Git funciona como "fonte de verdade", e o próprio cluster K8s sincroniza as alterações. Esse formato mantém o ambiente em um estado desejado de maneira declarativa, proporcionando mais flexibilidade e portabilidade.

### Pipeline de CI

O "pipeline" de CI para os 3 microsserviços da SolidaryTech cobre aspectos de qualidade e segurança do código, teste de integração de ponta a ponta contra a stack real, seguidos de build, scan e publicação de [imagens no Docker Hub][dockerhub].

O workflow (Gitea - [`.gitea/workflows/ci-cd.yaml`][cigitea] e GitHub - [`.github/workflows/ci-cd.yaml`][cigithub]) possuem uma divisão clara de responsabilidades em três estágios sequenciais:

1. **SAST/SCA por serviço**: lint (`golangci-lint` ou `ruff`), SCA de dependências via Trivy (_bloqueia CRITICAL_), e SAST (`gosec/bandit`, não bloqueante_);
2. **_"Smoke test"_ de ponta a ponta**: sobe a stack real via Docker Compose e executa o script `build/scripts/smoke-test.sh` contra os três serviços (_incluindo verificação da fila no ElasticMQ_);
3. **Build, scan de imagem e push**: construção de cada imagem, novo scan Trivy na imagem final e push para o Docker Hub (_`diasdmhub/{ngo,donation,volunteer}`_), com tag versionada como timestamp UTC (_para o Flux Image Automation_) e _latest_ quando a branch é `main`.

<BR>

## Gitops (CD)

O pipeline CI, combinado ao FluxCD, forma duas metades de um macrofluxo de GitOps.

### FluxCD

A SolidaryTech é gerenciada inteiramente pelo FluxCD a partir de definições em [`clusters/kubeadm-local/`][fluxcd], com o ojbetivo de fazer o _deploy_ dos serviços. Ele detecta quando novas tags são publicadas e faz o _commit_ na branch `main`. O ciclo é finalizado com o _Kustomization_ dos serviços, que aplicam a nova imagem no cluster.

São declaradas 3 conciliações com manifestos do Kubernetes:

1. [`kube/kube-aws`][kube] - Manifestos da SolidaryTech;
2. [`observe/`][observe] - Manifestos de serviços de monitoração e observabilidade (apenas no cluster local; no EKS, esses mesmos serviços são aplicados pelo Terraform - _ver `terra/README.md`_);
3. [`image-automation/`][imageauto] - Manifestos para atualização de imagens dos serviços.

<BR>

## Infraestrutura como Código (IaC)

O provisionamento de todo o ambiente (Cluster, Bancos de Dados, Mensageria, Rede, etc) é realizado via Terraform.

- Os recursos da AWS foram implementados como módulos do Terraform de modo a facilitar o gerenciamento, a manutenção e a realização de mudanças.
- Há consistência de tags em todos os recursos da AWS e do Kubernetes.
- Foco deliberado em recursos _Free-tier_ da AWS. No entanto, alguns custos são inevitáveis, como o control plane do EKS, o NAT Gateway e o EBS.

<BR>

## Kubernetes

> **O projeto foi estruturado em plataformas local de desenvolvimento e produção na AWS.**

Para desenvolver o ambiente, utilizou-se uma infraestrutura local de Kubernetes. Esse desenvolvimento começou com a implementação de uma _stack_ de serviços usando o Docker Compose. Em seguida, a _stack_ foi reorganizada em manifestos para _deploy_ em cluster K8s. Os recursos foram organizados separadamente, e receberam _labels_ padronizadas (`Project: SolidaryTech`, `Environment: primary`, `app.kubernetes.io/part-of`). Posteriormente o ambiente foi replicado na AWS.

O _deploy_ foi testado de ponta a ponta no cluster remoto, no qual os serviços da SolidaryTech compartilham um único _endpoint_ externo com portas TCP distintas para cada serviço. Dessa maneira, o ambiente se aproxima de um cenário de nuvem real com custo reduzido.

<BR>

## SRE

Foram definidos **SLIs de latência e erros** para todos os serviços da SolidaryTech. Por ser mais relevante, o Donation Service (_hot-path_) teve um SLO especificado de `98%`, o que estabelece um _error budget_ de `2%`.

Essa especificação se refere a um **período mensal** de `720h`, garantindo um mínimo de `705,6h` de disponibilidade do serviço e `14.4h` de tolerância a erros. Esses valores estabelecem uma margem de segurança para manutenções e atualizações do ambiente, se necessário, e mantêm um alta disponibilidade para os clientes.

A quebra do SLO implicará o congelamento imediato das atualizações programadas do Donation Service, exigindo a estabilização do ambiente até o próximo período mensal e o alívio do _error budget_.

Um conjunto de [dashboards do Grafana][dashgrafana] foi disponibilizado para apresentar os dados de saúde da SolidaryTech, incluindo os SLI/SLO mencionados e outros dados dos serviços. Essas dashboards podem ser sincronizadas com o repositório Git, complementando a estrutura de GitOps.

### Respostas a falhas e recuperação automática

Os mecanismos automáticos de nível de pod/node reduzem o MTTR de possíveis interrupções, sobrecargas e manutenções planejadas, eliminando, sobretudo, a intervenção humano nas classes de incidentes que eles conseguem reconhecer. Esses mecanismos são:

- Falha de contêineres - reinício pelo Kubernetes (_liveness probe_).
- Sobrecarga de CPU/Mem - absorvida pelo HPA (_1 a N réplicas_), que escala os pods horizontalmente até o limite dos _nodes_.
- Divergência de configuração - o FluxCD reconcilia o cluster com o repositório Git em até 5 minutos, se houver alterações diretamente no cluster.
- HPA e PDB - Mantêm o mínimo de pods ativos durante a manutenção do ambiente, evitando indisponibilidades.

> ⚠️ Nota
> - **As aplicações da SolidaryTech não possuem verificações de saúde reais, pois o `/health` é estático.**
> - **Os eventos de notificação com o SQS são considerados `fire-and-forget`, sem tratamento ou consumo real.**
> - **Esses aspectos estão fora do escopo do projeto, pois demandariam alterações na lógica das aplicações, conforme indicado no roteiro disponibilizado.**

Um ponto não automatizado é a indisponibilidade da camada de persistência (Postgres, DynamoDB, SQS). Essa camada é sensível e deve ser avaliada criteriosamente. Nesse caso, a detecção ocorre por meio da montoração ativa do ambiente (Grafana), com alertas de até 1m, e a resolução depende da intervenção humana, o que pode elevar o MTTR.

<BR>

## FinOps

### Tags

Quanto à estratégia de etiquetagem, foram adicionadas tags e prefixos aos recursos da SolidaryTech:

- O ambiente foi implementado por completo com o **Terraform**, aplicando as tags a seguir.

| Tag | Valor |
| :---: | :---: |
| Project | `SolidaryTech` |
| Environment | `Production` |
| CostCenter | `NGO-Core` |
| ManagedBy | `Terraform` |

- O padrão de "Tag Name" por recurso (`${PREFIXO}-<recurso>`) está presente em praticamente todos os recursos do Terraform para identificação individual ou por meio de filtros na AWS.

### Recursos

Considerando aspectos de consumo de recursos pelos _pods_, as características a seguir foram definidas para _**requests**_ e _**limits**_.

| Serviço | CPU request | CPU limit | Memória request | Memória limit |
| :---: | :---: | :---: | :---: | :---: |
| **ngo-service**       | `25m` | `150m` | `96Mi`  | `256Mi` |
| **donation-service**  | `40m` | `200m` | `64Mi`  | `256Mi` |
| **volunteer-service** | `25m` | `150m` | `128Mi` | `256Mi` |

- Os recursos de CPU e memória foram otimizados com base no histórico de uso real, obtido por meio da instrumentação de métricas dos serviços da SolidaryTech.
    - Vale destacar que o `donation-service` manteve _requests_ e _limits_ de CPU mais altos (`40m`/`200m`) do que os outros dois (`25m`/`150m`), o que é consistente com seu papel mais crítico da plataforma, conhecido como "**hot path**".
- Somente o **recurso HPA** foi utilizado para os serviços da SolidaryTech no cluster K8s, pois ele pode escalar automaticamente a quantidade de pods automaticamente e absorver picos de carga. Se a carga for reduzida, os pods serão reduzidos, assim como o consumo de recursos.
- O **VPA foi desconsiderado** nessa implementação, pois causaria divergência entre entre o repositório Git remoto e o cluster, e o FluxCD apresentaria um desvio (_drift_) a cada reconciliação.

### Custos

Para otimizar os custos, elaborou-se um [relatório contendo projeções ⤴️][estimativa] de gastos mensais baseadas em custos reais, e recomendações práticas para a otimização financeira do ambiente.

A implementação dos diversos recursos da AWS também incluiu estratégias para minimizar os custos, como a utilização de recursos _Free Tier_ e de opções de baixo custo.

<BR>

## Observabilidade e APM

Assim como na fase 4 do curso DCLT, por deliberação de projeto, **não é viável implementar as ferramentas de APM a seguir.**

- **Datadog**:
    - [Exige conexão com serviços de terceiros (como o GitHub)][datadog_edu] para acesso educativo.
    - Por meio de seu [pacote para estudantes][github_edu], o GitHub exige informações de identificação governamentais e um rastreamento biométrico altamente invasivo para registro.
    - Ambas as empresas coletam dados pessoais, comportamentais, biométricos e de rastreamento de usuários, que podem ser compartilhados com terceiros e utilizados para perfilarizações comerciais, marketing e treinamento de IA, entre outras ações. Tudo isso ocorre sem um prazo de retenção definido ou garantias reais de privacidade.
    - Mesmo assim, as tentativas de registro no programa educacional do GitHub **foram rejeitadas**. Uma das justificativas alegou que o aluno não tem proximidade geográfica com a **instituição de ensino, a qual aparentemente não indicou a oferta de estudo virtual na plataforma**.
    ![Github Rejection](./reject.png)
- **New Relic**:
    - O [**portal continua indisponível**][newrelic], pois tem recusado conexões (_ERR_CONNECTION_REFUSED_) durante o desenvolvimento desta fase. Não foi possível acessar os recursos do serviço.
- Diante dessas políticas e restrições, entendo que a filiação às instituições acima é inviável e invasiva. _Fico à disposição para maiores esclarecimentos._

### Tempo

O Grafana Tempo foi escolhido como a ferramenta de APM para esse ambiente, pois é acessível, oferece os recursos de rastreamento e observabilidade necessários para os serviços da SolidaryTech e já está integrado à ferramenta de observabilidade Grafana. Sua implementação e uso não geram custos iniciais, aderindo às premissas de otimização de custos esperadas pela organização.

A _stack_ completa foi implementada executando Prometheus, Loki, Tempo e Alloy (OTEL) que são enviados ao Grafana. Os códigos dos microserviços foram instrumentados para o APM do Tempo com _Distributed Tracing_.

- **Tracing distribuído**: OTLP dos 3 serviços, com correlação de log e trace via `trace_id` nas linhas de log, **equivalente ao "Log-Trace Correlation" do Datadog.**
- **Service map / RED metrics**: o _service-graphs processor_ do Tempo gera o mapa de dependências entre serviços, e o _span-metrics processor_ gera traces, incluindo dimensão extra para cobrir erros 4xx, o que é **equivalente ao Service Map + APM metrics do Datadog.**
- **Auto-instrumentação**: _opentelemetry-instrument_ nos serviços em Python e instrumentação manual em Go, **cobrindo o caso funcional, similar às bibliotecas usadas pelo agente Datadog.**
- **Infra metrics**: `kube-state-metrics` (estado de pods/deployments/daemonsets/statefulsets/nodes) e `node-exporter` (CPU/memória/disco/rede por node), coletados pelo próprio Prometheus, cobrem a camada de node/cluster, com **papel equivalente ao _Infrastructure Monitoring do Datadog._**

<BR>

## ITSM e AIOps

No que se refere aos aspectos de ITSM, o Zabbix é utilizado como ferramenta central de eventos, devido à sua flexibilidade com diversas ferramentas de mercado, e devido ao seu baixo custo, pois é open-source. Estão integrados a ele, estão recursos de tratamento e automação de eventos. No ambiente implementado, estão incluídos:

- alta performance em monitoramento e observabilidade;
- integração diversificada com plataformas de notificação;
- gerenciamento de eventos;
- personalização de mensagens e relatórios;
- ausência de custos de licenciamento;
- integração com IA;

<BR>

## Multicloud, Segurança e Disaster Recovery (DR)

Foi escolhida a estratégia de DR **ativo-passivo** entre duas regiões da AWS. Considerando o repositório Git, `terra/` é sempre o ambiente ativo, e `terra-dr/` reaplica os mesmos módulos em uma segunda região, geralmente sem nenhum recurso de processamento em execução. Os dados (uma réplica de leitura _"cross-region"_, sempre ativa, do RDS, com atraso tipicamente de segundos, e a tabela de voluntários no DynamoDB via _"Global Tables"_) são protegidos continuamente, enquanto a capacidade de processamento do ambiente passivo só é provisionada quando um desastre é declarado - _ver o [roteiro de ativação/failback ⤴️][roteirodr]_.

Essa estratégia está formalizada no [Plano de Continuidade de Negócios (PCN) ⤴️][pcn], com RTO e RPO estimados para os dados de doações, que é ativo mais crítico da plataforma.

<BR>

| [⬆️ Top](#estrutura-de-disciplinas---hackathon-solidarytech) |
| --- |

[cigitea]: /.gitea/workflows/ci-cd.yaml
[cigithub]: /.github/workflows/ci-cd.yaml
[fluxcd]: /clusters/kubeadm-local/
[kube]: /kube/
[observe]: /observe/
[imageauto]: /image-automation/
[dockerhub]: https://hub.docker.com/u/diasdmhub
[datadog_edu]: https://studentpack.datadoghq.com
[github_edu]: https://education.github.com/pack
[newrelic]: https://newrelic.com
[estimativa]: ./estimativa-custo.md
[pcn]: ./plano-continuidade-negocios.md
[roteirodr]: ./roteiro-dr-ativacao.md
[dashgrafana]: /doc/grafana/