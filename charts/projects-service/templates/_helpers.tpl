{{- define "projects-service.selectorLabels" -}}
app: {{ .Release.Name }}
{{- end }}