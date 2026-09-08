{{/*
Expand the name of the chart.
*/}}
{{- define "costfluent-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "costfluent-agent.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "costfluent-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "costfluent-agent.labels" -}}
helm.sh/chart: {{ include "costfluent-agent.chart" . }}
{{ include "costfluent-agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "costfluent-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "costfluent-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "costfluent-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "costfluent-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the secret containing the token
*/}}
{{- define "costfluent-agent.secretName" -}}
{{- if .Values.existingSecret.enabled }}
{{- .Values.existingSecret.name }}
{{- else }}
{{- include "costfluent-agent.fullname" . }}
{{- end }}
{{- end }}

{{/*
Get the token key in the secret
*/}}
{{- define "costfluent-agent.secretTokenKey" -}}
{{- if .Values.existingSecret.enabled }}
{{- .Values.existingSecret.tokenKey }}
{{- else -}}
token
{{- end }}
{{- end }}
