| [↩️ Voltar](/) |
| --- |

# Considerações para Otimização de Custos

Abaixo, são apresentadas algumas considerações do projeto relacionadas à infraestrutura tecnológica do ambiente, com foco na otimização de custos e possíveis _trade-offs_ aceitáveis.

<BR>

### Instâncias EC2

O uso de instâncias "free tier", como `m7i-flex.large` e `t3.micro`/`t3.small`, é um potencial redutor de custos de processamento. Quando combinado com o "Prefix delegation", habilitado por padrão no VPC CNI, o limite de pods por _node_ aumenta sem custo adicional, adiando a necessidade de mais _nodes_ à medida que a carga cresce.

### Rede

É usado apenas um NAT Gateway, já que este é um dos dois componentes que não têm "free tier" (junto ao control plane do EKS). Dessa forma, há uma redução mais direta do custo fixo mensal, considerada um _trade-off_ aceitável (perda de HA de NAT) em favor do custo.

Outro ponto é o uso de um único NLB compartilhado por todos os serviços e pela observabilidade, com _listeners/target groups_ adicionais, em vez de LBs dedicados a cada serviço. Dessa maneira, evita-se pagar por vários Network Load Balancers.

### Dados e Mensageria

O DynamoDB é usado como `PROVISIONED` (5/5) por padrão. Ele migra para `PAY_PER_REQUEST` somente quando o Global Tables/DR está ativo. Isso mantém o uso dentro da faixa "always-free" de 25/25 RCU/WCU enquanto o DR estiver desligado e há pagamento somente por _request_ quando a topologia multi-região for exigida.

Também é utilizado o "SQS Standard", não o "FIFO", pois ele permanece dentro do "free tier" de 1 milhão de requisições/mês, adequado ao volume esperado.

Optou-se por utilizar o SSM Parameter Store (_Standard tier_) em vez do Secrets Manager. Isso elimina o custo de aproximadamente `US$0,40` por secret/mês do Secrets Manager no caso de uso que não exige de rotação automática.

### Observabilidade

A _stack_ de observabilidade (Loki, Tempo, Alloy e Prometheus) está enviando os dados para o Grafana Cloud, evitando o custo de retenção de um SaaS de observabilidade e permitindo pagar apenas pelo processamento e armazenamento mínimos no cluster.

### CI/CD e imagens

Embora esperado, o uso do GitHub para CI também é um aspecto a se considerar, pois é gratuito para uso público e está altamente preparado para GitOps.

O uso do [Docker Hub][dockerhub] em vez do ECR otimiza o armazenamento, o gerenciamento e o compartilhamento de imagens de contêineres, pois ele possui alta capilaridade e permite o uso ilimitado de repositórios públicos. Ele tem o potencial de reduzir custos, já que não há cobrança pelo armazenamento de imagens, além de ser uma [plataforma de alta confiabilidade][dockerstatus].

### Disaster Recovery

A escolha do modelo "ativo-**passivo**", e não "ativo-_ativo_" reduz significativamente o custo, pois não mantém um cluster oscioso completo em execução. Nesse projeto, apenas a réplica de RDS (_cross-region_) e a "Global Table" do DynamoDB permanecem ativas, o que é o mínimo necessário para um RPO baixo.

| [⬆️ Top](#considerações-para-otimização-de-custos) |
| --- |

[dockerhub]: https://docs.docker.com/docker-hub
[dockerstatus]: https://www.dockerstatus.com