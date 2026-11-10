{{- define "projects-service.selectorLabels" -}}
app: {{ .Release.Name }}
{{- end }}

{{- define "projects-service.labels" -}}
app.kubernetes.io/name: {{.Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}