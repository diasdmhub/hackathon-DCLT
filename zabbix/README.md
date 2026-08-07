| [↩️ Voltar](../) |
| --- |

# Zabbix (EKS)

Métricas de infraestrutura do cluster EKS, equivalente ao Zabbix Agent
pré-existente usado em `kubeadm-local` (métricas de host - CPU, memória,
load average - ver `CLAUDE.md`), mas versionado e gerenciado pelo Flux:
diferente do Grafana Cloud (ver histórico em `observe-aws/README.md`), o
Zabbix já é self-hosted e não expõe um assistente de conexão dependente de
UI - uma `HelmRelease` comum é suficiente e confiável aqui.

Este diretório não existe em `kubeadm-local`: lá o Zabbix Agent já roda
pré-instalado nos 2 nodes, fora deste repositório.

## Componentes

| Componente | O que faz | Rede |
|---|---|---|
| **Zabbix Agent2** (DaemonSet) | Um pod por node do EKS, coleta métricas de host (CPU, memória, load, disco) | Sem exposição - conecta ativamente no proxy interno |
| **Zabbix Proxy** (modo ativo) | Recebe os checks ativos do agent2 e da API do Kubernetes, e retransmite tudo ao seu Zabbix server externo | Só **outbound**, porta 10051, via NAT Gateway - nenhuma porta do EKS precisa ficar acessível de fora |
| **kube-state-metrics** | Expõe `/metrics` com o estado dos objetos do Kubernetes (nodes, deployments, pods) | ClusterIP interno, alcançado pelo proxy via proxy da API do Kubernetes |
| **ServiceAccount `zabbix-k8s-reader`** | Identidade somente-leitura que o Zabbix usa para consultar a API do Kubernetes e o kube-state-metrics | Token de longa duração, sem exposição própria |

Tudo isso é gerenciado por `clusters/eks-aws/zabbix-kustomization.yaml` →
`./zabbix`, sem passo manual de `helm install` fora do Flux.

## Por que modo ativo (sem exposição de rede)

Ao contrário de `observe-aws/` (onde Loki/Tempo/Prometheus precisam ficar
alcançáveis pelo Grafana externo, daí os listeners na NLB restritos por
`observe_allowed_cidrs`), o Zabbix Proxy roda em **modo ativo**
(`ZBX_PROXYMODE: 0`): é ele quem abre a conexão para o seu Zabbix server, na
porta 10051, nunca o contrário. Isso significa:

- Nenhuma regra de Security Group nova é necessária no `terra/modules/nlb` -
  o tráfego sai pelo NAT Gateway já existente.
- O Zabbix server só precisa aceitar conexões de saída do EKS na porta
  10051 (mesma porta que ele já expõe para qualquer proxy ativo).

O Zabbix Agent2 (DaemonSet) segue o mesmo princípio: `ZBX_ACTIVE_ALLOW: true`
e `ZBX_PASSIVE_ALLOW: false`, então é o agent que se conecta ao proxy
(`zabbix-zabbix-proxy`, Service interno), nunca o proxy tentando alcançar um
IP de pod específico - o que seria frágil num DaemonSet (IP de pod muda a
cada reagendamento).

## Passos manuais (uma vez, no seu Zabbix server)

Assim como a conexão inicial com o Grafana Cloud foi um passo manual
documentado em `observe-aws/README.md`, a configuração do **lado do
servidor** Zabbix não é algo que o Flux/Kubernetes possa aplicar - ela vive
no banco de dados do seu Zabbix, configurada via UI ou API.

1. **Criar o Proxy**: *Data collection → Proxies → Create proxy*. Nome
   igual ao `zabbixProxy.ZBX_HOSTNAME` definido em
   `020-helmrelease-zabbix.yaml` (hoje `CHANGE_ME-solidarytech-eks-proxy` -
   ajuste os dois lados antes de aplicar). Modo: **Active**.

2. **Ajustar `ZBX_SERVER_HOST`** em `020-helmrelease-zabbix.yaml` para o
   hostname/IP real do seu Zabbix server (porta 10051), e fazer commit.

3. **Pegar o token da ServiceAccount de leitura**, depois que
   `zabbix-kustomization.yaml` tiver reconciliado:
   ```bash
   kubectl get secret zabbix-k8s-reader-token -n zabbix \
     -o jsonpath='{.data.token}' | base64 -d
   ```

4. **Pegar a URL da API do EKS**:
   ```bash
   terraform output -raw eks_cluster_endpoint   # em terra/
   ```

5. **Importar as templates nativas do Zabbix** (já vêm com o Zabbix 6.4+,
   não precisam de download): *Data collection → Templates → Kubernetes*,
   confirme que **"Kubernetes nodes by HTTP"** e **"Kubernetes cluster
   state by HTTP"** existem (caso seu Zabbix já tenha os hosts
   `kubernetes_nodes`/`kubernetes_cluster` do cluster local, como sugere
   `doc/grafana/dashboard-solidarytech.json`, você já usa essas templates -
   basta repetir o mesmo processo para o EKS).

6. **Criar os hosts do cluster EKS** a partir dessas templates, vinculados
   ao **Proxy** criado no passo 1 (não ao Zabbix server diretamente) - assim
   as consultas HTTP à API do Kubernetes e ao kube-state-metrics saem de
   dentro da VPC, através do proxy, em vez de exigir que o Zabbix server
   externo alcance o endpoint da API do EKS diretamente. Preencha as macros:
   - `{$KUBE.API.SERVER.URL}`: a URL do passo 4.
   - `{$KUBE.API.TOKEN}`: o token do passo 3.
   - `{$KUBE.NAMESPACE}` (se a template pedir, para localizar o
     kube-state-metrics): `zabbix`.

7. **Verificar**: no proxy, `kubectl logs -n zabbix -l app.kubernetes.io/component=proxy`
   deve mostrar a conexão ativa estabelecida com o Zabbix server. No
   Zabbix, o Proxy criado no passo 1 deve aparecer como "last seen" recente
   em *Data collection → Proxies*.

## O que não está incluso

- **PSK/criptografia** entre o proxy e o Zabbix server: o chart usado aqui
  (`zabbix-community/helm-zabbix`) não expõe campos de TLS/PSK como valores
  de primeira classe. Se sua política exigir, injete as variáveis
  `ZBX_TLS*` (documentadas nas imagens oficiais `zabbix/zabbix-proxy-sqlite3`
  e `zabbix/zabbix-agent2`) via `zabbixProxy.extraEnv`/`zabbixAgent.extraEnv`
  em `020-helmrelease-zabbix.yaml`.
- **Dashboard/alertas**: reaproveite o mesmo modelo de
  `doc/grafana/dashboard-solidarytech.json` e os triggers já configurados
  para os hosts `kubernetes_nodes`/`kubernetes_cluster` do cluster local -
  não há nada específico do EKS a versionar aqui além dos hosts criados no
  passo 6.

| [⬆️ Top](#zabbix-eks) |
| --- |
