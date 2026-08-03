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
| Coleta | Alloy artesanal (manifestos deste repo), gerenciado pelo Flux | Chart oficial `grafana/k8s-monitoring` (inclui Alloy), instalado manualmente com `helm install`/`helm upgrade` |
| Logs | Alloy → Loki local | Alloy (do chart) → Grafana Cloud, via OTLP |
| Traces | Alloy → Tempo local | Alloy (do chart) → Grafana Cloud, via OTLP |
| Métricas | Prometheus local, só recebendo remote_write do metrics-generator do Tempo | Nenhuma - `clusterMetrics`/`hostMetrics` do chart ficam desabilitados de propósito (métricas de cluster continuam com o Zabbix, ver `CLAUDE.md`) |
| Storage local (PVC/EBS) | Loki, Tempo e Prometheus têm PVC | Nenhum |
| Gerenciamento do chart | Flux (`HelmRepository`+`HelmRelease`) | Manual (`helm install`, fora do Flux) |

## Por que manual, e não um HelmRelease do Flux

Uma versão anterior deste diretório gerenciava o chart `grafana/k8s-
monitoring` 100% via Flux (`HelmRepository` + `HelmRelease`, com um Secret
`grafana-cloud-credentials` aplicado à parte). Na prática, os dados não
chegavam ao Grafana Cloud como esperado com essa configuração.

O Grafana Cloud é desenhado para uma conexão manual: o assistente "Connect a
Kubernetes cluster" da própria UI (**Connections → Add new connection →
Kubernetes**) gera um `helm install` já pronto, com a URL/credenciais do seu
stack embutidas ali mesmo. É esse comando que deve ser executado - uma única
vez por cluster - em vez de reconstruído manualmente num `HelmRelease`
versionado neste repo.

O que o Flux continua gerenciando aqui é só o `Namespace` (`000-namespace.yaml`),
mesmo padrão idempotente usado em `kube-aws/000-namespace.yaml` - sem risco,
já que criar um namespace não tem estado para divergir. O chart em si (que já
inclui o Alloy, via Alloy Operator) fica fora do Flux.

## Passo manual (uma vez por cluster)

1. No Grafana Cloud: **seu stack → Connections → Add new connection →
   Kubernetes**. Preencha o nome do cluster (`solidarytech-eks-cluster`) e
   selecione ao menos logs e traces (métricas de cluster não são necessárias
   aqui - ver tabela acima).
2. Copie o comando `helm install`/`helm upgrade` gerado pelo assistente
   (já inclui `helm repo add grafana ...`, `--namespace observe` e os valores
   de autenticação do seu stack).
3. Rode esse comando contra o cluster EKS, depois que o namespace `observe`
   existir (Flux já cria via `000-namespace.yaml`, ou o próprio comando com
   `--create-namespace` caso rode antes).
4. Se o token expirar ou for rotacionado, gere um novo comando na mesma tela
   e rode `helm upgrade` novamente - o Flux não participa desse ciclo.

Não versionar esse comando/script neste repo: ele traz o token do Grafana
Cloud embutido, então deve ficar só na máquina de quem aplica.

## Free tier do Grafana Cloud

O plano gratuito do Grafana Cloud inclui uma cota mensal sempre-grátis de
métricas, logs e traces (os limites exatos variam e mudam com o tempo -
confira no seu stack em Billing/Usage). Para o volume gerado por este
ambiente de hackathon, a cota gratuita deve ser suficiente; não há
provisionamento de infraestrutura AWS associado a isso (é conta/cota do
Grafana Cloud, não um recurso do `terra/`).

## Flux

`clusters/eks-aws/observe-kustomization.yaml` aponta para `./observe-aws`
(hoje só o `Namespace`) - e `clusters/eks-aws/solidarytech-kustomization.yaml`
para `./kube-aws` (ver `kube-aws/README.md`). Falta rodar o bootstrap do Flux
nesse cluster (`flux bootstrap ...` com `--path=./clusters/eks-aws`) para que
`flux-system/` seja gerado e essas Kustomizations passem a ser reconciliadas
de fato - ver `clusters/eks-aws/`.

Este cluster não roda a Kustomization `image-automation`: ela já reconcilia `./kube` a partir do `kubeadm-local` e faz commit+push direto na branch `main`; rodá-la também no EKS faria dois Flux checarem o Docker Hub e tentarem commitar a mesma atualização de tag em paralelo.

| [⬆️ Top](#observabilidade-da-aws) |
| --- |
