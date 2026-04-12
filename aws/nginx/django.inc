gzip on;
gzip_min_length 512;
gzip_proxied expired no-cache no-store private auth;
gzip_types text/plain text/css text/javascript application/javascript application/x-javascript application/json application/xml;
gzip_disable "msie6";

client_max_body_size 50M;
proxy_buffer_size 64k;
proxy_buffers 8 64k;

# All API traffic
location / {
    include /etc/nginx/asgi.inc;
    proxy_pass http://asgi_upstream;
}

# Health check (no logging)
location = /api/version {
    include /etc/nginx/asgi.inc;
    proxy_pass http://asgi_upstream;
    access_log off;
    log_not_found off;
}

# WebSocket route
location /ws/ {
    include /etc/nginx/asgi.inc;
    proxy_pass http://asgi_upstream;
}

# Static files
location /static/ {
    alias /opt/api/django/static/;
    access_log off;
    expires 30d;
}
