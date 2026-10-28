{{- define "stt-bench.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "stt-bench.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "stt-bench.name" . -}}
{{- end -}}
{{- end -}}

{{- define "stt-bench.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "stt-bench.labels" -}}
helm.sh/chart: {{ include "stt-bench.chart" . }}
app.kubernetes.io/name: {{ include "stt-bench.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "stt-bench.image" -}}
{{- $root := index . 0 -}}
{{- $image := index . 1 -}}
{{- $tag := $root.Values.images.tag -}}
{{- if and (gt (len .) 2) (index . 2) -}}{{- $tag = index . 2 -}}{{- end -}}
{{- printf "%s/%s/%s:%s" $root.Values.images.registry $root.Values.images.repository $image $tag -}}
{{- end -}}

{{- define "stt-bench.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
