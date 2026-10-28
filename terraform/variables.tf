variable "region" {
  description = "Região da AWS. Usada pelo provider aws e pelos módulos (VPC, EKS, ECR, SSM)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo de nome para todos os recursos."
  type        = string
  default     = "techchallenge"
}

variable "environment" {
  description = "Ambiente lógico (prod, staging). Obrigatória: vem de terraform/envs/<env>.tfvars no deploy.yml."
  type        = string

  # Sem default de propósito: staging e prod dividem a mesma conta AWS, e um
  # default "prod" faria um run sem o tfvars do ambiente subir recursos com nome
  # de produção (colisão ou sobrescrita).
  validation {
    condition     = contains(["prod", "staging"], var.environment)
    error_message = "environment precisa ser \"prod\" ou \"staging\"."
  }
}

variable "vpc_cidr" {
  description = "CIDR da VPC. Vira o ipBlock da NetworkPolicy do overlay aws consumido pelo repositório da aplicação. Sugestão: 10.0.0.0/16 em prod e 10.1.0.0/16 em staging."
  type        = string
  default     = "10.0.0.0/16"

  # Ternário (e não &&): o HCL não faz curto-circuito no &&. Com um valor sem
  # "/" (ex.: "abc"), o split(...)[1] estouraria antes de exibir a error_message.
  # O /20 exige prefixo <= /20.
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) ? tonumber(split("/", var.vpc_cidr)[1]) <= 20 : false
    error_message = "vpc_cidr precisa ser um CIDR válido com prefixo /20 ou menor (ex.: 10.0.0.0/16)."
  }
}

variable "kubernetes_version" {
  description = "Versão do control plane do EKS. Obrigatória: use uma versão ainda em suporte padrão (aws eks describe-cluster-versions --region us-east-1). Versões fora do suporte padrão entram em suporte estendido, com custo de cerca de 6x no control plane."
  type        = string

  # Sem default de propósito: qualquer valor fixo aqui fica velho em poucos
  # meses (o suporte padrão do EKS dura 14 meses por versão) e volta a gerar
  # custo extra sem ninguém perceber.
  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version precisa estar no formato 1.NN (ex.: 1.34)."
  }
}

variable "node_instance_types" {
  # t3.medium porque o default de lab_mode é true: o AWS Academy restringe os
  # tipos de instância, e é o tipo que o lab aceita.
  # Numa conta no plano AWS Free Tier, use c7i-flex.large: o Free Tier bloqueia
  # tipos fora da faixa gratuita com "InvalidParameterCombination - not eligible
  # for Free Tier", e o erro só aparece DEPOIS de criar o cluster, na hora de
  # subir o node group. Mesmos 2 vCPU / 4 GiB.
  # Evite os t4g.*: são ARM (Graviton) e a imagem é buildada para amd64.
  description = "Tipos de instância do managed node group. No AWS Academy, t3.medium; numa conta no plano gratuito, c7i-flex.large."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_group_size" {
  description = "Tamanho do managed node group. min >= 2 para o HPA ter onde espalhar. Sugestão: staging { min = 2, desired = 2, max = 2 }; prod { min = 2, desired = 2, max = 4 }."
  type = object({
    min     = number
    max     = number
    desired = number
  })
  default = {
    min     = 2
    max     = 4
    desired = 2
  }

  # Incoerência aqui passa no plan e só falha na API da AWS, depois de ~10 min
  # de apply — com o cluster já criado e cobrando.
  validation {
    condition = (
      var.node_group_size.min <= var.node_group_size.desired &&
      var.node_group_size.desired <= var.node_group_size.max &&
      var.node_group_size.min >= 1
    )
    error_message = "node_group_size precisa satisfazer 1 <= min <= desired <= max."
  }
}

variable "github_app_repository" {
  description = "owner/repo da aplicação autorizado a assumir a role de deploy via OIDC. Vazio desliga o recurso. Só tem efeito com lab_mode = false."
  type        = string
  default     = "DevKaue/tech-challenge-app"
}

variable "github_lambda_repository" {
  description = "owner/repo da Lambda de autenticação autorizado a assumir a role de deploy via OIDC. Vazio desliga o recurso. Só tem efeito com lab_mode = false. A grafia precisa bater exatamente com o repositório (a comparação na trust policy diferencia maiúsculas de minúsculas)."
  type        = string
  default     = "DevKaue/TechChallange---Function-Serverless"
}

variable "lab_mode" {
  description = "Modo AWS Academy (Learner Lab): a conta não permite criar roles de IAM nem provider OIDC. Ligado, cluster e nós usam a LabRole (veja lab_role_arn), sem IRSA e sem roles OIDC do GitHub, e ALB Controller e Kong usam a credencial do nó. Desligado = conta normal, com IRSA. É esta variável que liga/desliga o modo."
  type        = bool
  default     = true
}

variable "aws_account_id" {
  description = "ID da conta AWS (12 dígitos) usado para montar os ARNs da LabRole e da voclabs. Vazio = resolvido automaticamente pelas credenciais que rodam o plan/apply (data.aws_caller_identity) — o recomendado: nada específico por conta no código nem no pipeline."
  type        = string
  default     = ""

  validation {
    condition     = var.aws_account_id == "" || can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id precisa ser vazio ou um ID de conta AWS de 12 dígitos."
  }
}

variable "lab_role_arn" {
  description = "ARN completa da LabRole do AWS Academy. Vazio = montada automaticamente como arn:aws:iam::<conta>:role/LabRole, com a conta de aws_account_id (ou a das credenciais do run). Serve só para sobrescrever o nome/ARN da role (ex.: LabRole com outro nome); preencher ou não esta variável NÃO liga nem desliga o modo lab — isso é controlado por lab_mode."
  type        = string
  default     = ""

  validation {
    condition     = var.lab_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/", var.lab_role_arn))
    error_message = "lab_role_arn precisa ser vazio ou um ARN de role IAM (arn:aws:iam::<conta>:role/<nome>)."
  }
}

variable "cluster_admin_arns" {
  description = "ARNs de IAM com acesso admin ao cluster. Vazio = só quem criou."
  type        = list(string)
  default     = []
}

variable "cluster_readonly_arns" {
  description = "ARNs de IAM que recebem acesso somente-leitura ao namespace techchallenge (via grupo RBAC techchallenge:readonly)."
  type        = list(string)
  default     = []
}

variable "cluster_creator_arn" {
  description = "ARN da role que criou/cria o cluster EKS. Nulo = no modo lab, montada automaticamente como arn:aws:iam::<conta>:role/voclabs; fora do lab, o módulo mantém o comportamento original (resolução via aws_iam_session_context)."
  type        = string
  default     = null

  validation {
    condition     = var.cluster_creator_arn == null || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.cluster_creator_arn))
    error_message = "cluster_creator_arn precisa ser nulo ou um ARN de role IAM (arn:aws:iam::<conta>:role/<nome>)."
  }
}

variable "newrelic_license_key" {
  description = "License key (Ingest) do New Relic. Vem do secret NEW_RELIC_LICENSE_KEY do GitHub."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.newrelic_license_key) > 0
    error_message = "newrelic_license_key vazia: defina TF_VAR_newrelic_license_key no workflow."
  }
}
