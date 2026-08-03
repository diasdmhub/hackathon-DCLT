| [↩️ Voltar](../) |
| --- |

# Observabilidade da AWS

Equivalente a `observe/` (Loki + Alloy + Tempo + Prometheus locais) para o
ambiente EKS, mas usando o **Grafana Cloud** como backend de métricas, logs
e traces - sem Loki, Tempo nem Prometheus rodando no cluster, então sem PVC
nem EBS envolvidos aqui.

`observe/` continua existindo e válido como está, para o cluster
`kubeadm-local`. Nada neste diretório o altera.

## O que muda em relação a `observe/`

| | `observe/` (kubeadm-local) | `observe-aws/` (EKS) |
|---|---|---|
| Coleta | Alloy artesanal (manifestos deste repo) | Chart oficial `grafana/k8s-monitoring`, gerenciado por um `HelmRelease` do Flux |
| Logs | Alloy → Loki local | Alloy (do chart) → Grafana Cloud, via OTLP |
| Traces | Alloy → Tempo local | Alloy (do chart) → Grafana Cloud, via OTLP |
| Métricas | Prometheus local, só recebendo remote_write do metrics-generator do Tempo | Nenhuma - `clusterMetrics`/`hostMetrics` do chart ficam desabilitados de propósito (métricas de cluster continuam com o Zabbix, ver `CLAUDE.md`) |
| Storage local (PVC/EBS) | Loki, Tempo e Prometheus têm PVC | Nenhum |

## Por que um HelmRelease em vez do Alloy artesanal de `observe/`

A primeira versão deste diretório copiava o DaemonSet/RBAC do Alloy de
`observe/` com um `config.alloy` diferente (exportando para o Grafana Cloud
via variáveis de ambiente). Foi substituída pelo chart oficial
`grafana/k8s-monitoring` porque:

- É exatamente o que o assistente "Connect a Kubernetes cluster" do Grafana
  Cloud gera como `helm install` - só que aqui, gerenciado 100% pelo Flux
  (`010-helmrepository.yaml` + `030-helmrelease.yaml`), sem precisar rodar
  `helm install` manualmente em nenhum momento.
- O chart já resolve, com um único destino `otlp`, o que antes exigia 3
  destinos separados (URLs de push do Loki, do Tempo e do Prometheus) no
  `config.alloy` antigo - o Grafana Cloud aceita métricas, logs e traces
  numa única URL de "OTLP Gateway" com a mesma credencial.

O `helm-controller` do Flux já vem instalado desde o bootstrap (mesmo
`gotk-components.yaml` que instala `source-controller`/`kustomize-
controller`, usado tanto por `kubeadm-local` quanto por `eks-aws`), então
nenhum componente novo precisa ser adicionado ao cluster para isso
funcionar.

## Credenciais do Grafana Cloud

O Secret `grafana-cloud-credentials` **não é gerenciado pelo Flux** - é uma
credencial real (token do Grafana Cloud), diferente do
`AWS_ACCESS_KEY_ID=test` fake versionado em `kube/` para os emuladores
locais, e não deve ir para o git.

1. Copie `secret.example.yaml` para `secret.yaml` (já coberto pelo
   `.gitignore` da raiz do repositório).
2. Preencha `username` (Instance ID do seu stack) e `password` (o token da
   Access Policy) - instruções de onde encontrar cada um estão nos
   comentários do próprio arquivo.
3. Aplique manualmente, uma vez, depois que o namespace `observe` existir:
   ```bash
   kubectl apply -f observe-aws/secret.yaml
   ```

Se o token expirar ou for rotacionado, repita o passo 3 - o Flux não
precisa saber disso.

**Falta preencher também** a URL do OTLP Gateway em
`030-helmrelease.yaml` (`destinations.grafanaCloud.url`, hoje `"CHANGE_ME"`)
- não é sensível (é só a URL do seu stack, não uma credencial), por isso
fica no HelmRelease versionado em vez do Secret. Pegue o valor em **Grafana
Cloud → seu stack → Connections → Add new connection → OpenTelemetry
(OTLP)**.

## Free tier do Grafana Cloud

O plano gratuito do Grafana Cloud inclui uma cota mensal sempre-grátis de
métricas, logs e traces (os limites exatos variam e mudam com o tempo -
confira no seu stack em Billing/Usage). Para o volume gerado por este
ambiente de hackathon, a cota gratuita deve ser suficiente; não há
provisionamento de infraestrutura AWS associado a isso (é conta/cota do
Grafana Cloud, não um recurso do `terra/`).

## Flux

`clusters/eks-aws/observe-kustomization.yaml` já aponta para `./observe-aws` (e `clusters/eks-aws/solidarytech-kustomization.yaml` para `./kube-aws` - ver `kube-aws/README.md`). Falta rodar o bootstrap do Flux nesse cluster (`flux bootstrap ...` com `--path=./clusters/eks-aws`) para que `flux-system/` seja gerado e essas Kustomizations passem a ser reconciliadas de fato - ver `clusters/eks-aws/`.

Este cluster não roda a Kustomization `image-automation`: ela já reconcilia `./kube` a partir do `kubeadm-local` e faz commit+push direto na branch `main`; rodá-la também no EKS faria dois Flux checarem o Docker Hub e tentarem commitar a mesma atualização de tag em paralelo.

| [⬆️ Top](#observabilidade-da-aws) |
| --- |
