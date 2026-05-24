# orp_engine.conf.tpl — ORP Engine Nginx mTLS Gateway Template
# DO NOT deploy this file directly.
# Run nginx-setup.sh to generate /etc/nginx/http.d/orp_engine.conf
# with ${PKI_DIR} and ${FLASK_PORT} substituted via envsubst.

server {
    listen 9443 ssl default_server;
    listen [::]:9443 ssl default_server;
    server_name _;

    # ── TLS Identity & Encryption ────────────────────────────────
    ssl_certificate     ${PKI_DIR}/orp_server.crt;
    ssl_certificate_key ${PKI_DIR}/orp_server.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384';
    ssl_session_cache   shared:ORP_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # ── mTLS Shield ──────────────────────────────────────────────
    ssl_client_certificate ${PKI_DIR}/sovereign_root.crt;
    ssl_verify_client on;
    ssl_verify_depth 2;

    # ── Security Headers ─────────────────────────────────────────
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # ── Reverse Proxy to Gunicorn ────────────────────────────────
    location / {
        proxy_pass http://127.0.0.1:${FLASK_PORT};

        client_max_body_size 20M;
        proxy_read_timeout    120s;
        proxy_connect_timeout 10s;
        proxy_send_timeout    30s;

        proxy_set_header X-Operator-ID       $ssl_client_s_dn;
        proxy_set_header X-SSL-Client-Verify $ssl_client_verify;
        proxy_set_header Host                $host;
        proxy_set_header X-Real-IP           $remote_addr;
        proxy_set_header X-Forwarded-For     $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto   $scheme;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }

    # ── mTLS Certificate Error Page ──────────────────────────────
    error_page 495 496 @cert_error;

    location @cert_error {
        default_type text/html;
        return 403 '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
        <title>Access Denied — ORP Engine</title></head><body>
        <h1>Sovereign Identity Required</h1>
        <p>A valid operator certificate signed by the ORP Sovereign Root CA is required.</p>
        <code>HTTP 495/496 — Client Certificate Missing or Invalid</code>
        </body></html>';
    }
}
