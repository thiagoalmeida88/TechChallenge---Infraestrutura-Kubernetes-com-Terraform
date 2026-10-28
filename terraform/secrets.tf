# Segredo compartilhado de autenticação (HS256).
#
# O NAMESPACE e o Secret `techchallenge-secrets` da aplicação NÃO são criados
# aqui. Eles pertencem ao overlay `k8s/overlays/aws` do repositório da
# aplicação (namespace.yaml + secretGenerator no deploy.yml), que é dono único
# desses objetos. Criar os mesmos objetos no Terraform dava dois donos para o
# mesmo recurso e o último apply vencia — pior, com PASSWORD_SALT e
# WEBHOOK_SECRET divergentes, já que o deploy do app os lê dos secrets do
# GitHub environment. Como o namespace também existe no overlay (inclusive o
# `techchallenge-staging`), deixar o Terraform criá-lo duplicava o trabalho.
#
# O que permanece aqui é apenas o que é genuinamente compartilhado: o segredo
# dos tokens. A Lambda de CPF (que emite token de cliente) lê daqui em runtime,
# e o deploy da aplicação lê daqui para montar o Secret do app e as credenciais
# jwt dos KongConsumers. Fonte única: se cada um tivesse o seu, o Kong recusaria
# os tokens de quem estivesse divergente.
resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

resource "aws_ssm_parameter" "jwt_secret" {
  name        = "/${var.project}/${var.environment}/auth/jwt-secret"
  description = "Segredo HS256 compartilhado entre Lambda de autenticação, aplicação e Kong."
  type        = "SecureString"
  value       = random_password.jwt_secret.result
  tags        = local.tags
}
