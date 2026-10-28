# Observabilidade: nri-bundle do New Relic (infra K8s, eventos, Prometheus,
# eBPF e logs dos containers). A chave vem do secret NEW_RELIC_LICENSE_KEY
# do GitHub via TF_VAR_newrelic_license_key.
resource "helm_release" "newrelic" {
  name             = "newrelic-bundle"
  repository       = "https://helm-charts.newrelic.com"
  chart            = "nri-bundle"
  namespace        = "newrelic"
  create_namespace = true

  values = [yamlencode({
    global = {
      cluster     = module.eks.cluster_name
      lowDataMode = true
    }
    kube-state-metrics = {
      enabled = true
      image   = { tag = "v2.13.0" }
    }
    kubeEvents = { enabled = true }
    newrelic-prometheus-agent = {
      enabled     = true
      lowDataMode = true
      config = {
        kubernetes = { integrations_filter = { enabled = false } }
      }
    }
    nr-ebpf-agent       = { enabled = true }
    k8s-agents-operator = { enabled = true }
    logging             = { enabled = true }
    newrelic-logging    = { lowDataMode = true }
  })]

  set_sensitive {
    name  = "global.licenseKey"
    value = var.newrelic_license_key
  }

  depends_on = [module.eks]
}