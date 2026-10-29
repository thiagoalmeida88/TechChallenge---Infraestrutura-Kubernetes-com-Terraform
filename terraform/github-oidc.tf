# Roles de deploy pelo GitHub Actions SEM chave estática: o Actions troca seu
# token OIDC por credenciais temporárias da AWS. Nada de AWS_ACCESS_KEY_ID em
# secret de repositório.
#
# UM ROLE POR REPOSITÓRIO QUE AINDA DEPLOYA POR ACTIONS (aplicação e Lambda), e
# UM CONJUNTO POR AMBIENTE (o nome da role usa local.name). Cada role só pode ser
# assumida por jobs do GitHub Environment correspondente:
#   - apply de staging → repo:<owner>/<repo>:environment:staging
#   - apply de prod    → repo:<owner>/<repo>:environment:production
# Sem essa restrição, QUALQUER branch (ou PR) do repositório assumiria a role, e
# um workflow de staging poderia assumir a role de produção. Por isso os jobs de
# deploy PRECISAM declarar `environment: staging` ou `environment: production`.
#
# O Terraform DESTE repositório não tem role aqui: um pipeline não pode criar a
# role que ele mesmo precisa para rodar. Fora do lab, essa role (AWS_DEPLOY_ROLE
# no deploy.yml) é criada uma vez, à parte, como o bucket do bootstrap/.
#
# O provider OIDC é UM POR CONTA AWS, e staging e prod compartilham a conta. Por
# isso só o apply de prod o cria; o de staging apenas o consulta
# (data source). Consequência: aplique o prod ANTES do staging na primeira vez
# (ou o staging falha por não encontrar o provider). O infra-db também NÃO
# recria o provider: usa `data "aws_iam_openid_connect_provider"`.
#
# AWS Academy (local.lab_mode): nada deste arquivo é criado — a conta não
# permite provider OIDC nem roles. Os pipelines usam as credenciais temporárias
# do lab (access key, secret key e session token) nos secrets do GitHub de
# cada repositório (AWS_LAB_* aqui, no banco e na Lambda).
locals {
  github_app_role_enabled    = !local.lab_mode && var.github_app_repository != ""
  github_lambda_role_enabled = !local.lab_mode && var.github_lambda_repository != ""

  oidc_enabled = local.github_app_role_enabled || local.github_lambda_role_enabled

  # Só o prod cria o provider; os demais ambientes reaproveitam o da conta.
  oidc_create = local.oidc_enabled && var.environment == "prod"
  oidc_lookup = local.oidc_enabled && var.environment != "prod"

  # Nome do GitHub Environment que pode assumir as roles deste ambiente.
  github_environment = var.environment == "prod" ? "production" : var.environment

  # ARN do provider, venha de onde vier. one() evita erro de índice quando um dos
  # dois lados tem count = 0.
  github_oidc_provider_arn = one(concat(
    aws_iam_openid_connect_provider.github[*].arn,
    data.aws_iam_openid_connect_provider.github[*].arn,
  ))
}

data "tls_certificate" "github" {
  count = local.oidc_create ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.oidc_create ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = local.tags
}

# Staging (e qualquer ambiente que não seja prod): usa o provider criado pelo prod.
data "aws_iam_openid_connect_provider" "github" {
  count = local.oidc_lookup ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Deploy da APLICAÇÃO (repo techchallenge-app)
#    Push no ECR e `kubectl apply -k` no cluster. A autorização DENTRO do
#    cluster vem do access entry abaixo (IAM autentica, RBAC/ClusterAdmin
#    autoriza). É a role que o app repo configura como AWS_DEPLOY_ROLE.
# ─────────────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "assume_app" {
  count = local.github_app_role_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Só jobs que rodam no GitHub Environment deste ambiente.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_app_repository}:environment:${local.github_environment}"]
    }
  }
}

resource "aws_iam_role" "github_app_deploy" {
  count = local.github_app_role_enabled ? 1 : 0

  name               = "${local.name}-github-app-deploy"
  assume_role_policy = data.aws_iam_policy_document.assume_app[0].json

  tags = local.tags
}

data "aws_iam_policy_document" "github_app_deploy" {
  count = local.github_app_role_enabled ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.api.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }

  # Lê as credenciais do Postgres que o repositório de banco publica no SSM
  # (/techchallenge/<env>/db/{host,port,name,username,password}), para montar o
  # DATABASE_URL do .env.secret do overlay no deploy. SSM e não Secrets Manager:
  # é onde o repositório de banco grava (decisão registrada no secrets.tf dele).
  # A senha é SecureString com a chave gerenciada alias/aws/ssm, que não exige
  # kms:Decrypt explícito na policy.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/${var.environment}/db",
      "arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/${var.environment}/db/*",
    ]
  }

  # Lê o segredo JWT compartilhado (secrets.tf) para montar o Secret do app e as
  # credenciais jwt dos KongConsumers.
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [aws_ssm_parameter.jwt_secret.arn]
  }

  # Lê a license key do New Relic (newrelic.tf) para ligar o APM da API. ARN
  # montado, não referência ao recurso: o parâmetro só existe com a chave
  # configurada, e sem ele o deploy precisa receber ParameterNotFound (segue
  # com APM desligado), não AccessDenied (derruba o deploy).
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/${var.environment}/newrelic/license-key"]
  }
}

resource "aws_iam_role_policy" "github_app_deploy" {
  count = local.github_app_role_enabled ? 1 : 0

  name   = "deploy"
  role   = aws_iam_role.github_app_deploy[0].id
  policy = data.aws_iam_policy_document.github_app_deploy[0].json
}

resource "aws_eks_access_entry" "github_app_deploy" {
  count = local.github_app_role_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_app_deploy[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_app_deploy" {
  count = local.github_app_role_enabled ? 1 : 0

  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_app_deploy[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Deploy da LAMBDA (repo techchallenge-lambda)
#    Sem API Gateway da AWS: quem expõe a Lambda é o Kong (kong.tf), via plugin
#    aws-lambda. A role é assumida pelo repo DONO da lambda.
#
#    DESATUALIZADO: a policy abaixo foi escrita para `sam deploy`
#    (CloudFormation). O repositório da Lambda passou a publicar com Terraform e
#    imagem no ECR, que precisa de ecr:*, logs:* e leitura de SSM/VPC que esta
#    policy não dá. Só tem efeito fora do AWS Academy (lab_mode = false); no lab
#    a Lambda usa as credenciais temporárias e nada daqui é criado. Revisar
#    antes de usar numa conta normal.
# ─────────────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "assume_lambda" {
  count = local.github_lambda_role_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Só jobs que rodam no GitHub Environment deste ambiente.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_lambda_repository}:environment:${local.github_environment}"]
    }
  }
}

resource "aws_iam_role" "github_lambda_deploy" {
  count = local.github_lambda_role_enabled ? 1 : 0

  name               = "${local.name}-github-lambda-deploy"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda[0].json

  tags = local.tags
}

# ATENÇÃO (trade-off conhecido): o `sam deploy` cria a role de execução da
# função, então esta policy precisa de iam:CreateRole e iam:AttachRolePolicy. Com
# resources = ["*"], quem controla o pipeline consegue criar uma role com
# privilégios arbitrários. Aceitável neste desafio (a role só é assumível por um
# GitHub Environment do repo da Lambda); em produção real, restrinja os recursos
# de IAM ao prefixo do stack e adicione uma permissions boundary.
data "aws_iam_policy_document" "github_lambda_deploy" {
  count = local.github_lambda_role_enabled ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "cloudformation:CreateChangeSet",
      "cloudformation:DescribeChangeSet",
      "cloudformation:DescribeStacks",
      "cloudformation:ExecuteChangeSet",
      "cloudformation:GetTemplate",
      "cloudformation:ListStackResources",
      "cloudformation:CreateStack",
      "cloudformation:UpdateStack",
      "cloudformation:DeleteStack",
      "lambda:*",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "s3:CreateBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "iam:PassRole",
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "secretsmanager:GetSecretValue",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_lambda_deploy" {
  count = local.github_lambda_role_enabled ? 1 : 0

  name   = "deploy"
  role   = aws_iam_role.github_lambda_deploy[0].id
  policy = data.aws_iam_policy_document.github_lambda_deploy[0].json
}
