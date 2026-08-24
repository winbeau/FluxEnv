#!/bin/bash

config_meta_require_jq() {
    command -v jq >/dev/null 2>&1 || return 3
}

config_meta_validate_path() {
    local path=${1:-}

    [[ -n "$path" && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 5
    [[ -f "$path" && ! -L "$path" ]] || return 5
    return 0
}

config_meta_invalid_json() {
    local basename=$1
    local name=${basename%.json}

    jq -cn --arg basename "$basename" --arg name "$name" '
        {
            name: $name,
            basename: $basename,
            family: "invalid",
            variant: "",
            display_protocol: "invalid",
            server: null,
            server_port: null,
            transport: "",
            security: "",
            tls: false,
            reality: false,
            proxy_outbound_count: 0,
            local_type: null,
            local_listen: null,
            local_port: null,
            probe_supported: false,
            probe_reason: "invalid-json",
            metadata_status: "invalid",
            primary_outbound: null
        }
    '
}

config_meta_extract() {
    local path=${1:-}
    local basename=''
    local name=''

    (($# == 1)) || return 2
    config_meta_require_jq || return $?
    config_meta_validate_path "$path" || return $?

    basename=${path##*/}
    name=${basename%.json}
    if ! jq empty -- "$path" >/dev/null 2>&1; then
        config_meta_invalid_json "$basename"
        return 0
    fi

    jq -c --arg basename "$basename" --arg name "$name" '
        def valid_port:
            if type == "number" then
                (floor == . and . >= 1 and . <= 65535)
            else
                false
            end;

        def safe_text($value; $max):
            if ($value | type) == "string" and ($value | length) <= $max and
                (($value | test("[[:cntrl:]]")) | not) then
                $value
            else
                ""
            end;

        def safe_type($value):
            if ($value | type) == "string" and
                ($value | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")) then
                $value
            else
                "unknown"
            end;

        def safe_server($value):
            if ($value | type) == "string" and ($value | length) >= 1 and
                ($value | length) <= 253 and
                (($value | test("[[:cntrl:][:space:]/?#@]")) | not) then
                $value
            else
                null
            end;

        def is_proxy:
            ((.type? | type) == "string") and
            (.type != "direct" and .type != "block" and .type != "dns" and
             .type != "selector" and .type != "urltest");

        def is_group:
            .type == "selector" or .type == "urltest";

        def has_server:
            ((.server? | type) == "string") and ((.server? // "") | length) > 0;

        def has_server_port:
            has_server and (.server | safe_server(.) != null) and
                (.server_port? | valid_port);

        def tls_enabled:
            if (.tls? | type) == "object" then
                (.tls.enabled? == true)
            else
                false
            end;

        def reality_enabled:
            if (.tls? | type) == "object" and (.tls.reality? | type) == "object" then
                (.tls.reality.enabled? == true)
            else
                false
            end;

        def transport_name:
            if (.transport? | type) == "object" then
                safe_text(.transport.type? // ""; 32)
            else
                ""
            end;

        def classify($entry):
            if $entry == null then
                {
                    family: "unknown",
                    variant: "",
                    display_protocol: "unknown",
                    transport: "",
                    security: "",
                    tls: false,
                    reality: false
                }
            else
                ($entry.value) as $outbound |
                (safe_type($outbound.type? // "")) as $type |
                ($outbound | transport_name) as $transport |
                ($outbound | tls_enabled) as $tls |
                ($outbound | reality_enabled) as $reality |
                if $type == "vless" and $tls and $reality and
                    ($outbound.flow? == "xtls-rprx-vision") and
                    ($transport == "" or $transport == "tcp") then
                    {
                        family: "vless",
                        variant: "reality/vision",
                        display_protocol: "VLESS/TCP",
                        transport: "tcp",
                        security: "reality",
                        tls: true,
                        reality: true
                    }
                elif $type == "vless" and $tls and ($transport == "ws") and ($reality | not) then
                    {
                        family: "vless",
                        variant: "ws/tls",
                        display_protocol: "VLESS/WS",
                        transport: "ws",
                        security: "tls",
                        tls: true,
                        reality: false
                    }
                elif $type == "hysteria2" then
                    {
                        family: "hysteria2",
                        variant: "quic/tls",
                        display_protocol: "Hysteria2",
                        transport: "quic",
                        security: "quic-tls",
                        tls: true,
                        reality: false
                    }
                elif $type == "unknown" then
                    {
                        family: "unknown",
                        variant: "",
                        display_protocol: "unknown",
                        transport: $transport,
                        security: "",
                        tls: $tls,
                        reality: $reality
                    }
                else
                    {
                        family: $type,
                        variant: "",
                        display_protocol: $type,
                        transport: $transport,
                        security: (if $tls then "tls" else "" end),
                        tls: $tls,
                        reality: $reality
                    }
                end
            end;

        def primary_projection($entry):
            if $entry == null then
                null
            else
                ($entry.value) as $outbound |
                {
                    index: $entry.index,
                    type: safe_type($outbound.type? // ""),
                    server: safe_server($outbound.server? // ""),
                    server_port: (if ($outbound.server_port? | valid_port) then $outbound.server_port else null end),
                    transport: ($outbound | transport_name),
                    security: (
                        if ($outbound | reality_enabled) then "reality"
                        elif ($outbound | tls_enabled) then "tls"
                        else ""
                        end
                    ),
                    tls: ($outbound | tls_enabled),
                    reality: ($outbound | reality_enabled),
                    flow: safe_text($outbound.flow? // ""; 64)
                }
            end;

        . as $root |
        (($root.outbounds? // []) | if type == "array" then . else [] end) as $outbounds |
        [
            $outbounds | to_entries[] |
            select(.value | is_proxy) |
            {index: .key, value: .value}
        ] as $proxies |
        [
            $outbounds | to_entries[] |
            select(.value | is_group)
        ] as $groups |
        (
            $proxies | map(select(.value | has_server_port)) | .[0]
        ) as $server_primary |
        (($server_primary // $proxies[0]) // null) as $primary |
        (
            [
                (($root.inbounds? // []) | if type == "array" then . else [] end) |
                to_entries[] |
                .value as $inbound |
                select(($inbound.type? == "mixed" or $inbound.type? == "http" or $inbound.type? == "socks")) |
                select(($inbound.listen? == "localhost" or $inbound.listen? == "127.0.0.1" or $inbound.listen? == "::1")) |
                select(($inbound.listen_port? | valid_port)) |
                {index: .key, value: $inbound}
            ]
            | sort_by(
                if .value.type == "mixed" then 0
                elif .value.type == "http" then 1
                else 2
                end
            )
            | .[0]
        ) as $endpoint |
        (classify($primary)) as $classification |
        (
            if ($groups | length) > 0 then "selector-graph-unsupported"
            elif any(($root.inbounds[]?); (.type? == "tun" or .type? == "redirect" or .type? == "tproxy")) then "unsafe-inbound-type"
            elif any(($outbounds[]?); ((.tag? // "") != "")) and
                (([$outbounds[]?.tag? | select(type == "string" and length > 0)] | group_by(.) | map(select(length > 1)) | length) > 0) then "duplicate-outbound-tag"
            elif ($proxies | length) == 0 then "missing-server-metadata"
            elif ($proxies | length) > 1 then "multiple-proxy-outbounds"
            elif ($primary.value.detour? // "") != "" then "detour-chain-unsupported"
            elif ($primary.value | has_server_port | not) then "missing-server-metadata"
            elif ($classification.family != "vless" and $classification.family != "hysteria2") then "unsupported-outbound-type"
            elif ($classification.variant != "reality/vision" and $classification.variant != "ws/tls" and $classification.variant != "quic/tls") then "unsupported-outbound-type"
            else ""
            end
        ) as $probe_reason |
        {
            name: $name,
            basename: $basename,
            family: $classification.family,
            variant: $classification.variant,
            display_protocol: $classification.display_protocol,
            server: (if $primary == null then null else safe_server($primary.value.server? // "") end),
            server_port: (if $primary == null then null elif ($primary.value.server_port? | valid_port) then $primary.value.server_port else null end),
            transport: $classification.transport,
            security: $classification.security,
            tls: $classification.tls,
            reality: $classification.reality,
            proxy_outbound_count: ($proxies | length),
            local_type: (if $endpoint == null then null else $endpoint.value.type end),
            local_listen: (if $endpoint == null then null else $endpoint.value.listen end),
            local_port: (if $endpoint == null then null else $endpoint.value.listen_port end),
            probe_supported: ($probe_reason == ""),
            probe_reason: $probe_reason,
            metadata_status: (
                if ($classification.family == "unknown" or
                    ($classification.family != "vless" and $classification.family != "hysteria2")) then
                    "unknown"
                else
                    "ok"
                end
            ),
            primary_outbound: primary_projection($primary)
        }
    ' "$path"
}

config_meta_protocol_label() {
    local metadata=''

    (($# == 1)) || return 2
    metadata=$(config_meta_extract "$1") || return $?
    jq -r '.display_protocol // "unknown"' <<< "$metadata"
}

config_meta_primary_outbound_json() {
    local metadata=''

    (($# == 1)) || return 2
    metadata=$(config_meta_extract "$1") || return $?
    jq -c '.primary_outbound // null' <<< "$metadata"
}

config_meta_local_endpoint_json() {
    local metadata=''

    (($# == 1)) || return 2
    metadata=$(config_meta_extract "$1") || return $?
    jq -c '{type: .local_type, listen: .local_listen, port: .local_port}' <<< "$metadata"
}

config_meta_local_endpoint_tsv() {
    local metadata=''

    (($# == 1)) || return 2
    metadata=$(config_meta_extract "$1") || return $?
    jq -r 'if .local_type == null then empty else "\(.local_type)|\(.local_listen)|\(.local_port)" end' <<< "$metadata"
}

config_meta_probe_eligibility() {
    local metadata=''

    (($# == 1)) || return 2
    metadata=$(config_meta_extract "$1") || return $?
    jq -c '{supported: (.probe_supported == true), reason: (.probe_reason // "")}' <<< "$metadata"
}
