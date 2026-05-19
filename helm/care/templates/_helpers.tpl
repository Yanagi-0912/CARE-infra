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

{{- define "care.frontend.labels" -}}
{{ include "care.labels" . }}
app: {{ .Values.frontend.name }}
{{- end }}

{{- define "care.n8n.labels" -}}
{{ include "care.labels" . }}
app: n8n
{{- end }}

{{- define "care.publicOrigin" -}}
{{- printf "%s://%s" .Values.public.scheme .Values.public.host }}
{{- end }}

{{- define "care.n8nBaseUrl" -}}
{{- printf "%s://%s/n8n/" .Values.public.scheme .Values.public.host }}
{{- end }}

{{- define "care.corsAllowOrigins" -}}
{{- if .Values.backend.config.CORS_ALLOW_ORIGINS }}
{{- .Values.backend.config.CORS_ALLOW_ORIGINS }}
{{- else }}
{{- include "care.publicOrigin" . }}
{{- end }}
{{- end }}
