# Observabilidade: nri-bundle do New Relic (infra K8s, kube-state-metrics,
# eventos, Prometheus e logs dos containers). A chave vem do secret
# NEW_RELIC_LICENSE_KEY do GitHub via TF_VAR_newrelic_license_key.
#
# OPCIONAL, no mesmo critério do resto da infra: sem a chave (plan local, outra
# conta, scripts de operação, destroy), nada deste arquivo é criado e o plan
# segue normalmente. nonsensitive() só revela SE a chave existe, não o valor:
# count não aceita valor derivado de variável sensitive.
locals {
  newrelic_enabled = nonsensitive(var.newrelic_license_key != "")
}

# A mesma chave publicada no SSM para o deploy da aplicação, que liga o agente
# APM da API a partir de /techchallenge/<env>/newrelic/license-key (deploy.yml
# do repositório da aplicação). Sem o parâmetro, a API sobe com o APM desligado.
resource "aws_ssm_parameter" "newrelic_license_key" {
  count = local.newrelic_enabled ? 1 : 0

  name        = "/${var.project}/${var.environment}/newrelic/license-key"
  description = "License key (Ingest) do New Relic, lida pelo deploy da aplicação para o agente APM."
  type        = "SecureString"
  value       = var.newrelic_license_key
  tags        = local.tags
}

resource "helm_release" "newrelic" {
  count = local.newrelic_enabled ? 1 : 0

  name       = "newrelic-bundle"
  repository = "https://helm-charts.newrelic.com"
  chart      = "nri-bundle"
  # Versão fixa: há release quase toda semana, trazendo subcharts novos. Subir
  # a versão é PR explícito, depois de conferir o `helm template` com estes
  # values (mesmo padrão do Kong e do ALB Controller).
  version          = "8.0.39"
  namespace        = "newrelic"
  create_namespace = true

  # ~12 pods com imagens do docker.io em 2 nós: os 300 s padrão do helm podem
  # não bastar para todos ficarem prontos.
  timeout = 600

  # Num upgrade que falha (timeout, credencial do lab expirada no meio), apaga
  # o que a revisão nova criou, em vez de deixar o release `failed` com objetos
  # órfãos para o próximo run.
  cleanup_on_fail = true

  # Só o necessário para o desafio: métricas de nó/pod, kube-state-metrics,
  # eventos e logs. Ficam de fora (padrão do chart = desligado):
  #   - nr-ebpf-agent: DaemonSet privileged com hostNetwork, mais ingestão e
  #     superfície sem requisito que dependa dele;
  #   - k8s-agents-operator: auto-instrumentação por CR Instrumentation, sem
  #     uso porque a API já carrega o agente na própria imagem.
  values = [yamlencode({
    global = {
      cluster     = module.eks.cluster_name
      lowDataMode = true
    }
    kube-state-metrics = { enabled = true }
    kubeEvents         = { enabled = true }
    # Sem o plugin prometheus do Kong publicando métricas, ele coleta pouco de
    # útil e conta no volume de ingestão do plano gratuito.
    newrelic-prometheus-agent = {
      enabled     = true
      lowDataMode = true
      config = {
        kubernetes = { integrations_filter = { enabled = false } }
      }
    }
    logging          = { enabled = true }
    newrelic-logging = { lowDataMode = true }
  })]

  set_sensitive {
    name  = "global.licenseKey"
    value = var.newrelic_license_key
  }

  # Mesmo precedente do Kong: o chart cria Services e Deployments logo de cara,
  # e sem o ALB Controller pronto há corrida com o webhook dele. Os Jobs de
  # certificado do nri-metadata-injection precisam de DNS, e o CoreDNS é um
  # addon à parte do módulo EKS.
  depends_on = [
    module.eks,
    helm_release.alb_controller,
    aws_eks_addon.coredns,
  ]
}
