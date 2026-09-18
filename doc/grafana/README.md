| [↩️ Voltar](../../observe/) |
| --- |

# Dashboards do Grafana

Este diretório reúne os modelos de dashboard do Grafana da SolidaryTech, prontos para importação, e traz um _overview_ do que cada uma trata.

<BR>

## [SolidaryTech - Visão Geral](dashboard-solidarytech.json)

Dashboard interna de saúde da SolidaryTech, pensada para o dia a dia de operação. Reúne, numa única tela:

- **Números de negócio**: total de doações, valor arrecadado, ONGs e voluntários cadastrados, tanto no período selecionado quanto o total acumulado.
- **Mapa de serviços**: um diagrama visual de como os três microserviços (ONG, doação e voluntário) se comunicam entre si, com volume de chamadas, erros e latência em cada seta.
- **RED por serviço**: taxa de requisições, taxa de erro e latência (p50/p95/p99) de cada microserviço.
- **Hot Path**: atenção dedicada ao serviço de doações, apontado como o componente mais crítico da plataforma.
- **Logs de erro**: erros HTTP (4xx/5xx) recentes, com atalho direto para o _trace_ da requisição correspondente.
- **Saúde dos pods**: quantos pods de cada serviço estão de pé, prontos, e se algum reiniciou recentemente.
- **Recursos dos pods**: uso de CPU e memória de cada serviço, usado como referência para ajustar a capacidade alocada a cada um.

<BR>

## [SolidaryTech - Infraestrutura (Cluster)](dashboard-solidarytech-infra.json)

Dashboard focada na saúde da infraestrutura por trás da SolidaryTech. É uma visão separada da visão de negócio que ajuda a avaliar a saúde da infraestrutura e do cluster K8s.

- quantidade de servidores (nodes) do cluster;
- quantos pods estão em execução em cada área (SolidaryTech, observabilidade, cluster como um todo);
- consumo de cada servidor (CPU, memória, disco e carga).

<BR>

## [SolidaryTech - Golden Metrics (Latência e Erros)](dashboard-solidarytech-golden-metrics.json)

Dashboard de acompanhamento de metas de qualidade (SLO) por microserviço, organizada em duas abas:

- **Service SLI**: para cada um dos três serviços, a latência típica (p95) e a taxa de erro atuais, com seu histórico ao longo do tempo.
- **Donation SLO**: um recorte mensal (30 dias fixos) dedicado ao serviço de doações, mostrando se a meta de "95% das requisições respondidas em até ~500ms" e a meta de "95% das requisições sem erro" estão sendo cumpridas no mês.

É a dashboard de referência para responder "estamos cumprindo o nível de serviço combinado?", com foco especial no serviço de doações por ser o mais crítico da plataforma.

<BR>

## [SolidaryTech - Visão Externa](dashboard-solidarytech-externo.json)

Dashboard extra que simula a perspectiva de um cliente externo consultando a SolidaryTech por fora, sem acesso ao cluster (dados vindos do Zabbix, via monitoramento HTTP dos três serviços).

- **Saúde geral**: se os serviços estão no ar, e as mesmas contagens de ONGs e doações vistas de fora.
- **Indicadores da SolidaryTech**: latência e disponibilidade (SLI) baseada em eventos. Separada em visão diária, semanal e mensal de cada serviço, e quanto do "orçamento de erro" (error budget) tolerado já foi consumido em cada janela de tempo.
- **Eventos**: histórico de problemas/alertas detectados pelo monitoramento externo.

É a dashboard mais próxima de "como um cliente enxergaria a SolidaryTech".

<BR>

## [Contact Point - Zabbix Trapper](contact-point-zabbix-trapper.json)

Contact Point do Grafana Alerting que publica alertas num item Zabbix trapper via `history.push`, para centralizar alertas do Grafana no mesmo Zabbix que já cobre o monitoramento HTTP externo. É o export de um Contact Point criado pela UI do Grafana.

> ⚠️ **Este arquivo não é aplicável pelo Git Sync, pois essa funcionalidade só suporta "dashboards" e "folders" hoje. Para aplicar este "Contact Point", é necessário copiar este arquivo para `Grafana_DIR/provisioning/alerting/` no filesystem do host do Grafana, não pela UI. O Grafana Cloud não possui a funcionalidade de file provisioning, portanto, este Contact Point deve ser incluído manualmente.**

Para recriar o Contact Point na UI do Grafana, siga para `Alerting` → `Notification configuration` → `New contact point`, e preencha o formulário com, pelo menos, os valores abaixo.

- **URL**: a URL do `api_jsonrpc.php` do Zabbix.
- **Authorization Header - Scheme**: `Bearer`.
- **Authorization Header - Credentials**: o token de API Zabbix, com o usuário dono do token tendo permissão de API habilitada e permissão de escrita no host/grupo do item alvo.
- **Extra Headers**: `Content-Type: application/json-rpc`.
- **Custom Payload → Edit Payload Template**: Inclua o JSON a seguir.

```json
{
  "jsonrpc": "2.0",
  "method": "history.push",
  "params": [
    {"itemid": {{.Vars.zabbix_itemid}}, "value": "{{ monLabels.alertname     }}: {{ .Status }}"}
  ],
  "id": 1
}
```

- **Payload Variables**: uma entrada `zabbix_itemid` com o itemid Zabbix de destino (o item precisa ser do tipo "Zabbix trapper").

> ℹ️ **O Grafana só reporta "Test notification sent successfully" com base no status HTTP da resposta. A API JSON-RPC do Zabbix normalmente responde HTTP 200 mesmo quando o corpo contém um erro lógico (token inválido, sem permissão, itemid errado, tipo de item incompatível), então "sucesso" no Grafana não confirma sozinho que o Zabbix aceitou o valor.**

<BR>

## [Regras de Alerta - SolidaryTech](alert-rules-solidarytech.yaml)

Arquivo de regras no formato compatível com Prometheus/Mimir/Loki (`groups` → `rules`, cada uma com `alert`/`expr`/`for`/`labels`/`annotations`), o formato aceito por `Alerting` → `Alert rules` → `Import` do Grafana. Nesse formato a condição de disparo fica embutida na própria expressão PromQL (a regra dispara quando a consulta retorna algum resultado), e não há campo de datasource ou de contact point no arquivo: a tela de importação pede para escolher o datasource Prometheus, a pasta de destino e a regra de notificação; selecione o contact point `Zabbix` (acima) nesse passo. Cobrem os cenários considerados mais relevantes para o `donation-service` (Hot Path) e para a saúde dos pods:

- **solidarytech-donation-error-rate**: dispara quando a taxa de erro do `donation-service` fica acima de 5% por 5 minutos, tornando acionável a meta de 95% sem erro já definida na dashboard de Golden Metrics.
- **solidarytech-pods-unavailable**: dispara quando algum deployment do namespace `solidarytech` tem menos réplicas disponíveis do que o especificado, por 5 minutos — cobre os três serviços de uma só vez.
- **solidarytech-donation-silence**: dispara quando não há nenhuma chamada ao `donation-service` em 15 minutos, sustentado por 30 minutos. Não depende de erro ou de pod fora do ar: pega falhas silenciosas antes do serviço (ex.: SQS, NLB/Ingress) que RED e saúde de pods não enxergam.

> ⚠️ **Assim como o Contact Point acima, este arquivo não é aplicável pelo Git Sync (que só suporta dashboards e folders); é preciso importar pela UI (`Alerting` → `Alert rules` → `Import`), que exige YAML (JSON é rejeitado com "missing or invalid groups array"). Depois de importado, cada regra vira um alerta gerenciado pelo Grafana com o `expr` original como consulta única — confira se a pasta e o contact point (`Zabbix`) escolhidos na importação estão corretos antes de habilitar.**

| [⬆️ Top](#dashboards-do-grafana) |
| --- |