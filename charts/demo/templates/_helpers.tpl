{{/*
Chart 名称，长度受 Kubernetes label 限制。
*/}}
{{- define "demo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
完整资源名；release 名已包含 chart 名时直接复用 release 名。
*/}}
{{- define "demo.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
用于 Deployment selector、Service selector 和 ServiceMonitor selector 的稳定标签。
*/}}
{{- define "demo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: demo-service
{{- end }}

{{/*
用于所有资源的通用标签，供 Prometheus/ServiceMonitor 选择。
*/}}
{{- define "demo.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "demo.selectorLabels" . }}
app.kubernetes.io/version: {{ default .Chart.AppVersion .Values.appVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: observability-demo
{{- end }}
{{/* Digest takes precedence; tags are a build locator, not immutable identity. */}}
{{- define "demo.image" -}}
{{- $repository := required "image.repository is required" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" .Values.image.digest) -}}
{{- fail "image.digest must be sha256:<64 lowercase hex>" -}}
{{- end -}}
{{- printf "%s@%s" $repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s:%s" $repository (default .Chart.AppVersion .Values.image.tag) -}}
{{- end -}}
{{- end -}}
