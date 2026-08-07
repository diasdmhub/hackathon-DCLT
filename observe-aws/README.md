| [↩️ Voltar](../) |
| --- |

# Observabilidade da AWS

Equivalente a `observe/` (Loki + Alloy + Tempo + Prometheus locais) para o
ambiente EKS - mesma stack self-hosted, gerenciada pelo Flux, em vez do
Grafana Cloud.

`observe/` continua existindo e válido como está, para o cluster
`kubeadm-local`. Nada neste diretório o altera.

## Histórico: por que não Grafana Cloud

Uma versão anterior deste diretório usava o Grafana Cloud como backend
(chart `grafana/k8s-monitoring`, instalado manualmente com `helm install`).
Na prática, configurar essa conexão se mostrou trabalhoso e frágil: a
documentação do Grafana Cloud nem sempre corresponde à nomenclatura atual da
UI, e o assistente de "Connect a Kubernetes cluster" também diverge em
alguns pontos - sem ganho líquido sobre simplesmente rodar a mesma stack já
validada em `observe/`. Este diretório foi reescrito para espelhar
`observe/`, com Loki/Tempo/Prometheus rodando no próprio cluster EKS, sob o
Flux, como já acontece em `kubeadm-local`.

## O que muda em relação a `observe/`

| | `observe/` (kubeadm-local) | `observe-aws/` (EKS) |
|---|---|---|
| Storage local (PVC) | `storageClassName: local-path` | `storageClassName: gp3` (default provisionada por `terra/modules/eks`, via EBS CSI) |
| Exposição externa (Loki/Tempo/Prometheus) | `Service` `type: LoadBalancer`, IP fixo compartilhado do MetalLB (`allow-shared-ip`) | `Service` `type: ClusterIP` + `TargetGroupBinding` por backend, na mesma NLB única de `kube-aws/` (`terra/modules/nlb`) |
| Ingress dessas portas (3100/3200/9090) | Rede local, sem regra de firewall neste repo | Security Group do EKS, restrito a `observe_allowed_cidrs` (`terra/terraform.tfvars`) - **não** `0.0.0.0/0`, já que Loki/Tempo/Prometheus não têm autenticação própria |
| Tudo o mais (Deployments, configs do Loki/Tempo/Prometheus, DaemonSet do Alloy, RBAC) | idêntico | idêntico |

## Exposição externa: NLB única + TargetGroupBinding

Mesmo modelo de `kube-aws/` (ver `kube-aws/README.md`): os 3 backends
(`loki`, `tempo`, `prometheus`) são `Service` `type: ClusterIP`, e cada um
tem um `TargetGroupBinding` referenciando por nome determinístico
(`targetGroupName: solidarytech-<backend>-tg`) um target group provisionado
por `terra/modules/nlb`, na mesma NLB dos 3 microsserviços - portas
3100/3200/9090 adicionadas como novos listeners, sem criar uma NLB separada.

Diferente das portas de aplicação (8081/8082/8083, abertas a `0.0.0.0/0`),
a regra de Security Group dessas 3 portas é restrita a
`var.observe_allowed_cidrs` (`terra/variables.tf`, sem default de propósito
- defina o CIDR, IP ou domínio real, tipicamente de onde o seu Grafana
externo consulta, em `terra/terraform.tfvars`). Loki, Tempo e Prometheus não
têm autenticação própria; abrir essas portas para a internet exporia logs,
traces e métricas de negócio a qualquer IP.

Cada entrada de `observe_allowed_cidrs` pode ser um CIDR, um IP solto (vira
`/32`) ou um nome de domínio - útil para quem consulta a partir de um IP
dinâmico associado a um domínio DDNS. Domínios são resolvidos via DNS
(provider `hashicorp/dns`, `terra/dns.tf`) a cada `terraform plan`/`apply`;
se o IP por trás do domínio mudar entre um apply e outro, a regra só
acompanha no próximo `terraform apply`.

`clusters/eks-aws/observe-kustomization.yaml` declara `dependsOn:
lb-controller`, pelo mesmo motivo de `solidarytech-kustomization.yaml`: o
CRD `TargetGroupBinding` precisa existir antes desses manifests serem
aplicados.

## Configuração no Grafana

O Grafana continua externo ao cluster (mesmo modelo de `observe/`), mas
aponta para o DNS name da NLB (`terraform output nlb_dns_name` em `terra/`,
ou o mesmo DNS já usado pelos 3 microsserviços) em vez do IP do MetalLB:

- Loki: `http://<nlb_dns_name>:3100`
- Tempo: `http://<nlb_dns_name>:3200`
- Prometheus: `http://<nlb_dns_name>:9090`

O restante da configuração (Service Graph, derived field de `trace_id`,
dashboard modelo) é idêntico ao descrito em `doc/observabilidade.md` para o
cluster local - só a URL dos datasources muda.

## Traces

Mesma instrumentação de `observe/` (ver `doc/observabilidade.md`): os 3
microsserviços exportam OTLP para o Alloy deste cluster
(`http://alloy.observe.svc.cluster.local:4318`, configurado via
`OTEL_EXPORTER_OTLP_ENDPOINT` nos Deployments de `kube-aws/`), que roteia
logs ao Loki e traces ao Tempo local.

## Métricas de infraestrutura (Zabbix)

Métricas de cluster/host (CPU, memória, load, estado dos nodes/deployments)
não passam por este diretório - ver `zabbix/README.md` para a stack de
Zabbix Proxy + Agent2 deste cluster, equivalente ao Zabbix Agent
pré-existente usado em `kubeadm-local`.

## Flux

`clusters/eks-aws/observe-kustomization.yaml` aponta para `./observe-aws` e
reconcilia todo este diretório (namespace, PVCs, Deployments, DaemonSet do
Alloy, Services e `TargetGroupBinding`) - nada aqui é aplicado manualmente,
diferente do fluxo antigo do Grafana Cloud.

Este cluster não roda a Kustomization `image-automation`: ela já reconcilia
`./kube` a partir do `kubeadm-local` e faz commit+push direto na branch
`main`; rodá-la também no EKS faria dois Flux checarem o Docker Hub e
tentarem commitar a mesma atualização de tag em paralelo.

| [⬆️ Top](#observabilidade-da-aws) |
| --- |
