# observe-aws/

Equivalente a `observe/` (Loki + Alloy + Tempo + Prometheus locais) para o
ambiente EKS, mas usando o **Grafana Cloud** como backend de métricas, logs
e traces - sem Loki, Tempo nem Prometheus rodando no cluster, então sem PVC
nem EBS envolvidos aqui.

`observe/` continua existindo e válido como está, para o cluster
`kubeadm-local`. Nada neste diretório o altera.

## O que muda em relação a `observe/`

| | `observe/` (kubeadm-local) | `observe-aws/` (EKS) |
|---|---|---|
| Logs | Alloy → Loki local | Alloy → Loki do Grafana Cloud |
| Traces | Alloy → Tempo local | Alloy → Tempo do Grafana Cloud (OTLP/HTTP) |
| Métricas | Prometheus local, só recebendo remote_write do metrics-generator do Tempo | Pipeline OTLP → Prometheus remote_write para o Mimir do Grafana Cloud (hoje sem uso real - ver observação abaixo) |
| Storage local (PVC/EBS) | Loki, Tempo e Prometheus têm PVC | Nenhum |

O RBAC e o DaemonSet do Alloy em `020-alloy/` são cópias dos de `observe/`
(o Kustomize não permite referenciar arquivos fora da árvore do diretório
atual) com uma diferença: o container ganha `envFrom` apontando para o
Secret `grafana-cloud-credentials`, e o `config.alloy` montado é outro
(`observe-aws/config.alloy`, não `observe/020-alloy/config.alloy`).

## Observação sobre métricas

Hoje nenhum dos 3 microsserviços emite métricas customizadas (só logs e
traces - ver `CLAUDE.md`). O pipeline `otelcol.receiver.otlp` → ... →
`prometheus.remote_write` em `config.alloy` existe pronto para quando isso
mudar, mas por ora fica praticamente ocioso.

As métricas RED/service-graph que o Tempo local gerava via
`metrics_generator` (customizado em `observe/030-tempo/config.yaml` para
também contar 4xx - ver `CLAUDE.md`) deixam de existir como estão hoje: o
Tempo do Grafana Cloud tem seu próprio metrics-generator/Application
Observability, mas normalmente sem o mesmo nível de customização via YAML
que um Tempo self-hosted permite. Vale conferir nas configurações do seu
stack do Grafana Cloud (Tempo > Application Observability ou Service Graph)
se dá para reproduzir o mesmo comportamento de contar 4xx - se não der, é
uma perda de funcionalidade a aceitar ao migrar para o Grafana Cloud, não
algo que este Kustomization resolve.

## Credenciais do Grafana Cloud

O Secret `grafana-cloud-credentials` **não é gerenciado pelo Flux** - é uma
credencial real (token do Grafana Cloud), diferente do
`AWS_ACCESS_KEY_ID=test` fake versionado em `kube/` para os emuladores
locais, e não deve ir para o git.

1. Copie `secret.example.yaml` para `secret.yaml` (já coberto pelo
   `.gitignore` da raiz do repositório).
2. Preencha os valores reais - instruções de onde encontrar cada um estão
   nos comentários do próprio arquivo (Grafana Cloud > Connections > Add
   new connection, para as URLs/usernames; Administration > Access
   Policies, para o token).
3. Aplique manualmente, uma vez, depois que o cluster/namespace existir:
   ```bash
   kubectl apply -f observe-aws/secret.yaml
   ```

Se o token expirar ou for rotacionado, repita o passo 3 - o Flux não
precisa saber disso.

## Free tier do Grafana Cloud

O plano gratuito do Grafana Cloud inclui uma cota mensal sempre-grátis de
métricas, logs e traces (os limites exatos variam e mudam com o tempo -
confira no seu stack em Billing/Usage). Para o volume gerado por este
ambiente de hackathon, a cota gratuita deve ser suficiente; não há
provisionamento de infraestrutura AWS associado a isso (é conta/cota do
Grafana Cloud, não um recurso do `terra/`).

## Pendência: Flux precisa apontar para cá

Assim como `kube/` e `observe/` são aplicados hoje pelas Kustomizations em
`clusters/kubeadm-local/`, o cluster EKS vai precisar de um bootstrap do
Flux próprio (`clusters/eks-aws/` ou nome equivalente) com uma
Kustomization apontando para `./observe-aws` (e outra para `./kube`, e
outra para `./image-automation`). Isso ainda não existe neste repositório -
ver a resposta sobre Flux no EKS na conversa que motivou este diretório.
