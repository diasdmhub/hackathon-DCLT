| [↩️ Voltar](./) |
| --- |

# Estrutura de disciplinas - "Hackathon" SolidaryTech

> ⚠️ **_Em construção_**

Abaixo são descritas algumas das disciplinas utilizadas neste projeto.

<BR>

## 1. Fundamentos DevOps

O projeto utiliza algumas disciplinas principais de DevOps, conforme descrito a seguir.

<BR>

### 1.1 **Container**

- Dockerfiles otimizados para o _build_ dos 3 microserviços e implantação no Kubernetes.
    - Os microserviços e acessórios utilizam imagens reduzidas, como `alpine`.
    - Possuem _stage build_ otimizado para redução de artefatos quando necessário (_donation-service_).
- Três microserviços independentes (`ngo-service`, `donation-service` e `volunteer-service`), cada um com seu próprio banco/storage (Postgres, Postgres+SQS e DynamoDB, respectivamente).
- Stack completa em `build/docker-compose.yaml`, incluindo emuladores locais de nuvem: ElasticMQ (SQS) e DynamoDB Local, para não depender de conta AWS real durante desenvolvimento e testes.

<BR>

### 1.2 CI e DevSecOps

Trata-se de um modelo onde o Git é a fonte de verdade e o próprio cluster K8s puxa as mudanças. Esse formato mantém o ambiente em um estado desejado de forma declarativa trazendo mais flexibilidade e portabilidade.

🔶 **Gitea e GitHub com pipeline de CI** - Pipeline de CI para os 3 microsserviços do SolidaryTech, cobrindo aspectos de qualidade e segurança de código, teste de integração de ponta a ponta contra a stack real, seguidos de build, scan e publicação de [imagens no Docker Hub][dockerhub].

Os dois workflows equivalentes ([`.gitea/workflows/ci-cd.yaml`][cigitea] e [`.github/workflows/ci-cd.yaml`][cigithub]) possuem uma divisão de responsabilidades clara com três estágios sequenciais:

1. **SAST/SCA por serviço**: lint (`golangci-lint` ou `ruff`), SCA de dependências via Trivy (_bloqueia CRITICAL_), e SAST (`gosec/bandit`, não bloqueante_).
2. **_Smoke test_ de ponta a ponta**: sobe a stack real via docker compose e executa o script `build/scripts/smoke-test.sh` contra os três serviços (_incluindo checagem da fila no ElasticMQ_).
3. **Build, scan de imagem e push**: construção de cada imagem, novo scan Trivy na imagem final e push para o Docker Hub (_`diasdmhub/{ngo,donation,volunteer}`_), com tag versionada como timestamp UTC (_para o Flux Image Automation_) e _latest_ quando a branch é `main`.

<BR>

### 1.3 Gitops (CD)

O pipeline CI combinado ao FluxCD formam duas metades de um macro fluxo de GitOps.

🔶 **FluxCD** - O cluster é gerenciado inteiramente pelo FluxCD, a partir das definições em [`clusters/kubeadm-local/`][fluxcd] a fim de fazer o _deploy_ dos serviços. Ele detecta quando novas tags são publicadas e faz o _commit_ na branch `main`. O ciclo se fecha com o Kustomization dos serviços que aplicam a nova imagem no cluster.

São declarados 3 conciliações com manifestos do Kubernetes:

1. [`kube/kube-aws`][kube] - Manifestos da SolidaryTech.
2. [`observe/`][observe] - Manifestos de serviços de monitoração e observabilidade (só no cluster local; no EKS, esses mesmos serviços são aplicados pelo Terraform - ver `terra/README.md`).
3. [`image-automation/`][imageauto] - Manifestos para atualização de imagens dos serviços.

<BR>

### 1.4 Infraestrutura como Código (IaC)

Provisionamento de todo o ambiente (Cluster, Bancos de Dados, Mensageria, Rede) via Terraform.

- Os recursos da AWS foram implementados como módulos do Terraform de modo a facilitar o gerenciamento e possíveis manutenções.
- Consistência de tags em todos os recursos AWS e Kubernetes, tanto para o ambiente local como para o ambiente _cloud_.

<BR>

### 1.5 Kubernetes

> **O projeto foi estruturado em plataformas de desenvolvimento e produção.**

🔶 **3.1 K8s local** - Para desenvolver o ambiente, foi utilizado uma infraestrutura de Kubernetes local. Esse desenvolvimento foi iniciado com a implementação de uma _stack_ de serviços com o Docker Compose. Em seguida, a _stack_ foi reorganizada em manifestos para _deploy_ em cluster K8s. Os recursos foram organizados separadamente, e labels padronizadas (`Project: SolidaryTech`, `Environment: dev`, `app.kubernetes.io/part-of`).

Deploy testado ponta a ponta no cluster real. Os serviços da SolidaryTech compartilham um único _endpoint_ externo com portas distintas por serviço, aproximando o ambiente local de um cenário de nuvem real com custo reduzido.

<BR>

### 1.6 Observabilidade e APM

Stack completa rodando (Prometheus, Grafana, Loki e/ou Alloy) e instrumentação dos códigos no APM (Tempo) com Distributed Tracing.

<BR>

## SRE

<BR>

## FinOps

<BR>

## ITSM e AIOps

<BR>

## Multicloud, Segurança e Disaster Recovery (DR)

<BR>

## Artefatos

- Documentação de arquitetura e teste manual em `doc/`.

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
