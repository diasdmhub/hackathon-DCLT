# lb-controller/

Instala o [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
no cluster EKS, via Flux (`HelmRepository` + `HelmRelease`). É pré-requisito
do modelo de endpoint único usado em `kube-aws/`: os 3 microsserviços expõem
`Service` `type: ClusterIP` (não `LoadBalancer`), e um recurso
`TargetGroupBinding` por serviço (definido em `kube-aws/`) registra os pods
nos target groups de uma única NLB provisionada pelo Terraform
(`terra/modules/nlb`) - equivalente ao IP fixo compartilhado via MetalLB
(`allow-shared-ip`) usado em `kubeadm-local`, mas com a NLB como recurso de
primeira classe do Terraform em vez de originada por um `Service`
`LoadBalancer` (que criaria uma ELB por serviço, fora do state do Terraform).

O controller em si não expõe nada publicamente aqui - ele só reconcilia o
CRD `TargetGroupBinding`, registrando/removendo os IPs de pod nos target
groups conforme os Deployments escalam. A NLB, os listeners (8081/8082/8083)
e os target groups já existem antes disso, criados por `terra/modules/nlb`.

## IRSA

`000-serviceaccount.yaml` cria a ServiceAccount `aws-load-balancer-controller`
no namespace `kube-system`, anotada com o ARN da role IRSA que
`terra/modules/lb-controller` provisiona (a mesma política IAM oficial do
projeto, `terra/modules/lb-controller/iam_policy.json`). O `HelmRelease`
(`020-helmrelease.yaml`) usa `serviceAccount.create: false` para o chart
reaproveitar esta ServiceAccount em vez de criar uma sem a anotação de role.

## Ordem de aplicação

`clusters/eks-aws/solidarytech-kustomization.yaml` declara `dependsOn:
lb-controller` (com health check no `HelmRelease`), para o Flux garantir que
o controller (e o CRD `TargetGroupBinding` que o chart instala) já exista
antes de aplicar os `TargetGroupBinding` de `kube-aws/`.

## Versão do chart

`020-helmrelease.yaml` fixa `version: "3.5.0"` (chart `aws-load-balancer-controller`
do repositório `eks-charts`, https://aws.github.io/eks-charts) - atualize
manualmente ao revisar a versão; este diretório não está no escopo do Flux
Image Automation (`image-automation/`, que só cobre as imagens dos 3
microsserviços).
