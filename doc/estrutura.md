| [↩️ Voltar](./) |
| --- |

# Estrutura de disciplinas - "Hackathon" SolidaryTech

> ⚠️ **_Em construção_**

Abaixo são descritas algumas das disciplinas utilizadas neste projeto.

<BR>

## Fundamentos DevOps

- **Infraestrutura como Código (IaC)** - Provisionamento de todo o ambiente (Cluster, Bancos de Dados, Mensageria, Rede) via Terraform.

<BR>

### **Container e Kubernetes** - Monolito local

- Dockerfiles otimizados para o _build_ dos 3 microserviços e implantação no Kubernetes.
    - Os microserviços e acessórios utilizam imagens reduzidas, como `alpine`.
    - Possuem _stage build_ otimizado para redução de artefatos quando necessário (_donation-service_).
- Três microserviços independentes (`ngo-service`, `donation-service` e `volunteer-service`), cada um com seu próprio banco/storage (Postgres, Postgres+SQS e DynamoDB, respectivamente).
- Stack completa em `build/docker-compose.yaml`, incluindo emuladores locais de nuvem: ElasticMQ (SQS) e DynamoDB Local, para não depender de conta AWS real em desenvolvimento.
- Documentação de arquitetura e teste manual em `doc/`.

<BR>

### 2. GitOps

🔶 **2.1 Gitea e GitHub com pipeline de CI** - Pipeline de CI para os 3 microsserviços do SolidaryTech, cobrindo aspectos de qualidade e segurança de código, teste de integração de ponta a ponta contra a stack real, seguidos de build, scan e publicação de imagens no Docker Hub.

Dois workflows equivalentes ([`.gitea/workflows/ci-cd.yaml`][cigitea] e [`.github/workflows/ci-cd.yaml`][cigithub]), com três estágios sequenciais:

1. **SAST/SCA por serviço**: lint (_golangci-lint ou ruff_), SCA de dependências via Trivy (_bloqueia CRITICAL_), e SAST (_gosec/bandit, não bloqueante_).
2. **_Smoke test_ de ponta a ponta**: sobe a stack real via docker compose e executa o script `build/scripts/smoke-test.sh` contra os três serviços (_incluindo checagem da fila no ElasticMQ_).
3. **Build, scan de imagem e push**: build de cada imagem, novo scan Trivy agora na imagem final, login e push para o Docker Hub (_`diasdmhub/{ngo,donation,volunteer}`_), com tag versionada por SHA e latest quando a branch é `main`.

🔶 **2.2 FluxCD para CD** - O cluster kubernetes é integrado com o [FluxCD][fluxcd] para gerenciar automaticamente o _deploy_ dos serviços através do "Kustomize". São declarados 3 conciliações por meio de manifestos do Kubernetes, trazendo mais flexibilidade e portabilidade:

1. [`kube/`][kube] - Manifestos da SolidaryTech.
2. [`observe/`][observe] - Manifestos de serviços de monitoração e observabilidade.
3. [`image-automation/`][imageauto] - Manifestos para atualização de imagens dos serviços.
4. [`clusters/kubeadm-local/`] - Manifestos para a integração do FluxCD.

<BR>

### 3. Kubernetes

> **O projeto foi estruturado em plataformas de desenvolvimento e produção.**

🔶 **3.1 K8s local** - Para desenvolver o ambiente, foi utilizado uma infraestrutura de Kubernetes local. Esse desenvolvimento foi iniciado com a implementação de uma _stack_ de serviços com o Docker Compose. Em seguida, a _stack_ foi reorganizada em manifestos para _deploy_ em cluster K8s.

- Conversão completa da stack de `docker-compose.yaml` para manifestos em `kube/`, organizados por sequência numérica (_`000-namespace`, `010-db`, `020-elasticmq`, `030-dynamodb`, `040-ngo`, `050-donation`, `060-volunteer`_), com recursos organizados separadamente, e labels padronizadas (`Project: SolidaryTech`, `Environment: dev`, `app.kubernetes.io/part-of`).
- Deploy testado ponta a ponta no cluster real. Os três serviços compartilham um único IP externo com portas distintas por serviço, aproximando o ambiente local de um cenário de nuvem real.

<BR>

| [⬆️ Top](#estrutura-de-disciplinas---hackathon-solidarytech) |
| --- |

[cigitea]: /.gitea/workflows/ci-cd.yaml
[cigithub]: /.github/workflows/ci-cd.yaml
[fluxcd]: /clusters/kubeadm-local/
[kube]: /kube/
[observe]: /observe/
[imageauto]: /image-automation/
