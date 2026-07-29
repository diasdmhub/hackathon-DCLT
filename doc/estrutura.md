| [↩️ Voltar](./) |
| --- |

# Estrutura de disciplinas - "Hackathon" SolidaryTech

> ⚠️ **_Em construção_**

Abaixo são descritas algumas das disciplinas utilizadas neste projeto.

<BR>

## Fundamentos DevOps

- **Container e Kubernetes** - "Dockerfiles" otimizados para o _build_ dos 3 microserviços e implantação no Kubernetes.
    - Os microserviços e acessórios utilizam imagens reduzidas, como `alpine`.
    - Possuem _stage build_ otimizado para redução de artefatos quando necessário (_donation-service_).
        - _Vide arquivos `Dockerfile-*` na raiz do repositório._

- **Infraestrutura como Código (IaC)** - Provisionamento de todo o ambiente (Cluster, Bancos de Dados, Mensageria, Rede) via Terraform.

- **CI/CD e DevSecOps** - Pipeline de CI/CD ([`.gitea/workflows/ci-cd.yaml`][cicd]) para os 3 microsserviços do SolidaryTech, cobrindo aspectos de qualidade e segurança de código, teste de integração de ponta a ponta contra a stack real, seguidos de build, scan e publicação de imagens no Docker Hub.

- **GitOps** - Entrega contínua configurada através do FluxCD.

<BR>

| [⬆️ Top](#estrutura-de-disciplinas---hackathon-solidarytech) |
| --- |

[cicd]: /.gitea/workflows/ci-cd.yaml