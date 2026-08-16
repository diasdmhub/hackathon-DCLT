# Zabbix Proxy (modo ativo) + Zabbix Agent2 (DaemonSet), via o chart
# zabbix-community/helm-zabbix - equivalente ao antigo zabbix/020-helmrelease-
# zabbix.yaml (Flux), agora aplicado direto pelo Terraform via provider helm.
# Ver README.md deste módulo para o desenho completo e os passos manuais no
# lado do Zabbix server.
#
# Só proxy + agent ficam habilitados: zabbixServer/zabbixWeb/
# zabbixWebService/postgresql continuam desligados de propósito, já que o
# Zabbix server, o frontend web e o banco já existem fora deste cluster.
#
# Fluxo de dados: zabbix-agent2 (DaemonSet, um por node) -> zabbix-proxy
# (dentro do cluster, modo ativo) -> Zabbix server externo, porta 10051. Só
# o proxy sai do cluster (outbound, via NAT Gateway); nada entra.
resource "helm_release" "zabbix" {
  name       = "zabbix"
  namespace  = kubernetes_namespace_v1.zabbix.metadata[0].name
  repository = "https://zabbix-community.github.io/helm-zabbix"
  chart      = "zabbix"
  version    = "7.1.0"

  values = [
    yamlencode({
      # O chart só traz por padrão a versão LTS (7.0) do Zabbix; para usar
      # uma versão non-LTS (ex: 7.4) é preciso sobrescrever essa tag
      # manualmente (ver comentário do values.yaml do chart). "ol-<versão>-
      # latest" é a variante Oracle Linux com patch mais recente da minor
      # (equivalente ao "ubuntu-<versão>-latest", trocado para bater com a
      # distro deste ambiente). Atenção: o proxy precisa estar em versão
      # igual ou compatível com o Zabbix server externo
      # (var.zabbix_server_host) - confirme lá antes de aplicar, um proxy
      # mais novo que o server não se conecta.
      zabbixImageTag = "ol-${var.zabbix_version}-latest"

      zabbixServer     = { enabled = false }
      postgresql       = { enabled = false }
      zabbixWeb        = { enabled = false }
      zabbixWebService = { enabled = false }

      zabbixProxy = {
        enabled = true
        # 0 = proxy ativo: a conexão com o Zabbix server sai sempre daqui de
        # dentro (porta 10051), sem exigir nenhuma regra de ingress no EKS.
        ZBX_PROXYMODE   = 0
        ZBX_SERVER_PORT = 10051

        # PSK na conexão de saída (proxy -> Zabbix server externo, a única
        # que atravessa a borda do cluster). O chart não tem campos
        # dedicados para nenhuma dessas 3 variáveis (só ZBX_PROXYMODE/
        # ZBX_HOSTNAME/ZBX_SERVER_HOST/ZBX_SERVER_PORT/... são lidas
        # diretamente do template - ver comentário do "set" mais abaixo),
        # então todas entram via extraEnv. O valor da PSK em si NUNCA vai
        # como env var (ficaria visível em "kubectl describe pod") - vem de
        # um arquivo montado a partir do Secret
        # kubernetes_secret_v1.zabbix_proxy_psk (ver extraVolumes abaixo e
        # psk.tf).
        extraEnv = [
          {
            name  = "ZBX_TLSCONNECT"
            value = "psk"
          },
          {
            name  = "ZBX_TLSPSKIDENTITY"
            value = var.zabbix_proxy_tls_psk_identity
          },
          {
            name  = "ZBX_TLSPSKFILE"
            value = "/run/secrets/zabbix-proxy-psk/tls_psk_file"
          },
        ]
        extraVolumeMounts = [
          {
            name      = "tls-psk"
            mountPath = "/run/secrets/zabbix-proxy-psk"
            readOnly  = true
          },
        ]
        extraVolumes = [
          {
            name = "tls-psk"
            secret = {
              secretName = kubernetes_secret_v1.zabbix_proxy_psk.metadata[0].name
            }
          },
        ]
      }

      zabbixAgent = {
        enabled = true
        # DaemonSet (um agent por node do EKS), não sidecar do proxy -
        # métrica de host (CPU/memória/load) por node, equivalente ao
        # Zabbix Agent pré-existente em kubeadm-local.
        runAsSidecar    = false
        runAsDaemonSet  = true
        hostNetwork     = true
        hostRootFsMount = true
        # Checks ativos: o agent conecta no proxy (nunca o contrário), então
        # não é preciso um Host por node com IP de pod fixo no Zabbix.
        ZBX_PASSIVE_ALLOW = false
        ZBX_ACTIVE_ALLOW  = true
        # Nome do Service do zabbix-proxy gerado pelo chart:
        # "<name>-zabbix-proxy" = "zabbix-zabbix-proxy" (release "zabbix").
        # NÃO defina ZBX_ACTIVESERVERS também: o entrypoint do agent2 já
        # prepende ZBX_SERVER_HOST à lista de ServerActive quando
        # ZBX_ACTIVE_ALLOW=true, então repetir o mesmo valor nas duas causa
        # "address ... specified more than once" e o agent entra em
        # CrashLoopBackOff.
        ZBX_SERVER_HOST = "zabbix-zabbix-proxy"

        # As probes padrão do chart fazem tcpSocket na porta "zabbix-agent"
        # (10050, o listener passivo). Como ZBX_PASSIVE_ALLOW=false acima
        # desliga esse listener, a porta nunca abre, a probe falha sempre e
        # o kubelet mata o container em loop (CrashLoopBackOff) mesmo com o
        # agent funcionando normalmente em modo active-only. Troca para uma
        # exec probe que testa localmente, sem depender de porta de rede.
        # tcpSocket = null é necessário porque o merge de values do Helm é
        # por chave: sem isso, a chave "exec" só se soma à "tcpSocket" do
        # default do chart em vez de substituí-la, e o Kubernetes rejeita o
        # DaemonSet por ter mais de um handler type na mesma probe.
        startupProbe = {
          tcpSocket = null
          exec = {
            command = ["zabbix_agent2", "-t", "agent.ping"]
          }
          initialDelaySeconds = 15
          periodSeconds       = 5
          timeoutSeconds      = 3
          failureThreshold    = 5
          successThreshold    = 1
        }
        livenessProbe = {
          tcpSocket = null
          exec = {
            command = ["zabbix_agent2", "-t", "agent.ping"]
          }
          timeoutSeconds   = 3
          failureThreshold = 3
          periodSeconds    = 10
          successThreshold = 1
        }
      }
    })
  ]

  # ZBX_HOSTNAME/ZBX_SERVER_HOST identificam o Zabbix server real - vêm de
  # var.zabbix_hostname/var.zabbix_server_host (terraform.tfvars, não
  # versionado) via "set" em vez do bloco values acima, no lugar do antigo
  # Secret zabbix-proxy-env aplicado manualmente fora do Flux.
  set = [
    {
      name  = "zabbixProxy.ZBX_HOSTNAME"
      value = var.zabbix_hostname
    },
    {
      name  = "zabbixProxy.ZBX_SERVER_HOST"
      value = var.zabbix_server_host
    },
  ]
}

# kube-state-metrics: expõe /metrics com o estado dos objetos do Kubernetes
# (nodes, deployments, pods...). É a peça que falta para usar as templates
# nativas do Zabbix "Kubernetes nodes by HTTP" / "Kubernetes cluster state
# by HTTP" (ver README.md deste módulo). Valores padrão do chart bastam: só
# precisamos do Service (porta 8080) acessível via proxy da API do
# Kubernetes.
#
# name = "zabbix-kube-state-metrics" (não só "kube-state-metrics"): o script
# de preprocessing da template oficial "Kubernetes cluster state by HTTP"
# faz "GET api/v1/endpoints" (cluster-wide) e filtra pelo nome exato do
# objeto Endpoints, contra a macro {$KUBE.STATE.ENDPOINT.NAME}, cujo default
# na template é "zabbix-kube-state-metrics" - sem bater esse nome, a
# descoberta falha com "Cannot get state metrics endpoints from Kubernetes
# API". O helper "fullname" padrão do chart usa o nome do release como nome
# do Service/Endpoints quando ele já contém "kube-state-metrics", então só
# nomear o release assim já alinha com o default da template, sem precisar
# editar a macro manualmente no Zabbix.
resource "helm_release" "kube_state_metrics" {
  name       = "zabbix-kube-state-metrics"
  namespace  = kubernetes_namespace_v1.zabbix.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = "8.1.3"
}
