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
- **CI/CD e DevSecOps** - Pipelines automatizados com o GitHub Actions, contemplando testes, scans de segurança (SAST/SCA como ferramentas como Trivy/Sonar) e build da imagem.
- **GitOps** - Entrega contínua configurada através do FluxCD.

<BR>

| [⬆️ Top](#fiap---hackathon-fase-5---solidarytech) |
| --- |