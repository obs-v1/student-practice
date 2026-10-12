{{/* Image reference: explicit repository/tag wins, otherwise the global registry. */}}
{{- define "fault-injector.image" -}}
{{- $fi := .Values.faultInjector -}}
{{- $repo := $fi.image.repository | default (printf "%s/fault-injector" .Values.global.registry) -}}
{{- $tag := $fi.image.tag | default .Values.global.imageTag -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
