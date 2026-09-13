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

| [⬆️ Top](#dashboards-do-grafana) |
| --- |
