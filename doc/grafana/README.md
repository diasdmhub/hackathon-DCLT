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

Contact Point do Grafana Alerting que publica alertas num item Zabbix trapper via `history.push`, para centralizar alertas do Grafana no mesmo Zabbix que já cobre o monitoramento HTTP externo (ver dashboard "Visão Externa" acima). É o export real de um Contact Point criado, testado e confirmado (`"response":"success"` na resposta do Zabbix) manualmente pela UI do Grafana — não um provisioning file de import direto: a versão local do Grafana usada neste projeto não aceitou o formato clássico `apiVersion: 1` + `contactPoints:` via provisioning por arquivo, provavelmente por usar o mecanismo mais novo baseado em manifests estilo Kubernetes.

Como recriar na UI do Grafana (Alerting → Contact points → New):

- **URL**: a URL do `api_jsonrpc.php` do Zabbix.
- **Authorization Header - Scheme**: `Bearer`.
- **Authorization Header - Credentials**: o token de API Zabbix (Users → API tokens), com o usuário dono do token tendo permissão de API habilitada e permissão de escrita no host/grupo do item alvo.
- **Extra Headers**: `Content-Type: application/json-rpc` (sobrescreve o `application/json` default do Grafana).
- **Custom Payload → Edit Payload Template**: o template em `settings.payload.template` deste arquivo, referenciando `{{ .Vars.zabbix_itemid }}`.
- **Payload Variables**: uma entrada `zabbix_itemid` com o itemid Zabbix de destino (o item precisa ser do tipo "Zabbix trapper", habilitado, com o Value type compatível com o valor enviado). Manter o itemid como variável, em vez de fixo no template, facilita trocar o item sem reescrever o template.

Como os `payload.vars` são fixos por Contact Point (não variam por alerta), este modelo assume um Contact Point por item Zabbix. Para rotear alertas diferentes a itens diferentes, crie um Contact Point por item (cada um com seu próprio `zabbix_itemid`) e use as notification policies do Grafana para direcionar por label — ou, para um único alerta que dispara vários itens de uma vez, adapte o template para iterar em `.Alerts` e ler o itemid de um label do alerta em vez de `.Vars`.

Um ponto que vale registrar como referência de depuração: o Grafana só reporta "notificação enviada com sucesso" com base no status HTTP da resposta. A API JSON-RPC do Zabbix normalmente responde HTTP 200 mesmo quando o corpo contém um erro lógico (token inválido, sem permissão, itemid errado, tipo de item incompatível), então "sucesso" no Grafana não confirma sozinho que o Zabbix aceitou o valor — reproduzir a chamada com curl e inspecionar o corpo da resposta foi o que revelou os nomes de campo corretos neste caso.

| [⬆️ Top](#dashboards-do-grafana) |
| --- |
