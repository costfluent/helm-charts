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
The Secret holding the token: the named one, or the chart's own when agent.token is set.
*/}}
{{- define "costfluent-agent.secretName" -}}
{{- if .Values.agent.secret.name -}}
{{- .Values.agent.secret.name -}}
{{- else if .Values.agent.token -}}
{{- include "costfluent-agent.fullname" . -}}
{{- else -}}
{{- required "set agent.token, or agent.secret.name for an existing Secret holding the token" "" -}}
{{- end -}}
{{- end }}

{{- define "costfluent-agent.secretKey" -}}
{{- if .Values.agent.secret.name -}}
{{- .Values.agent.secret.key | default "token" -}}
{{- else -}}
token
{{- end -}}
{{- end }}

{{- define "costfluent-agent.dataDir" -}}
{{- if .Values.persist -}}
{{- .Values.persist.mountPath | default "/var/lib/costfluent" -}}
{{- else -}}
/var/lib/costfluent
{{- end -}}
{{- end }}
