{{- define "care.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "care.fullname" -}}
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

{{- define "care.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}

{{- define "care.labels" -}}
helm.sh/chart: {{ include "care.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "care.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "care.backend.labels" -}}
{{ include "care.labels" . }}
app: {{ .Values.backend.name }}
{{- end }}

{{- define "care.scheduler.labels" -}}
{{ include "care.labels" . }}
app: {{ .Values.scheduler.name }}
{{- end }}

{{- define "care.frontend.labels" -}}
{{ include "care.labels" . }}
app: {{ .Values.frontend.name }}
{{- end }}

{{- define "care.n8n.labels" -}}
{{ include "care.labels" . }}
app: n8n
{{- end }}

{{- define "care.asr.labels" -}}
{{ include "care.labels" . }}
app: local-asr
{{- end }}

{{- define "care.parser.labels" -}}
{{ include "care.labels" . }}
app: local-parser
{{- end }}

{{- define "care.publicOrigin" -}}
{{- printf "%s://%s" .Values.public.scheme .Values.public.host }}
{{- end }}

{{- define "care.publicBaseUrl" -}}
{{- if .Values.backend.config.PUBLIC_BASE_URL }}
{{- .Values.backend.config.PUBLIC_BASE_URL }}
{{- else }}
{{- include "care.publicOrigin" . }}
{{- end }}
{{- end }}

{{- define "care.n8nBaseUrl" -}}
{{- printf "%s://%s/n8n/" .Values.public.scheme .Values.public.host }}
{{- end }}

{{/*
n8n Webhook node 註冊的路徑。單一來源：backend 打的網址與 n8n 註冊的路徑
都從這裡推導，避免兩邊各自寫死而分岔。
*/}}
{{- define "care.n8nWebhookPath" -}}
{{- .Values.n8n.provisioning.webhookPath }}
{{- end }}

{{/*
backend 呼叫 n8n 的媒體解析 webhook。
留空 backend.config.MEDIA_PARSE_WEBHOOK_URL 時由叢集內位址 + webhookPath 組出；
要指向叢集外的 n8n 才在 values 填絕對網址覆寫。
*/}}
{{- define "care.mediaParseWebhookUrl" -}}
{{- if .Values.backend.config.MEDIA_PARSE_WEBHOOK_URL }}
{{- .Values.backend.config.MEDIA_PARSE_WEBHOOK_URL }}
{{- else }}
{{- printf "http://n8n-service:%v/webhook/%s" .Values.n8n.service.port (include "care.n8nWebhookPath" .) }}
{{- end }}
{{- end }}

{{- define "care.corsAllowOrigins" -}}
{{- if .Values.backend.config.CORS_ALLOW_ORIGINS }}
{{- .Values.backend.config.CORS_ALLOW_ORIGINS }}
{{- else }}
{{- include "care.publicOrigin" . }}
{{- end }}
{{- end }}
