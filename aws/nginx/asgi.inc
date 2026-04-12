proxy_http_version      1.1;

proxy_set_header        Host                $host;
proxy_set_header        X-Forwarded-For     $proxy_add_x_forwarded_for;
proxy_set_header        X-Forwarded-Proto   $scheme;
proxy_set_header        X-Real-IP           $remote_addr;

proxy_set_header        Upgrade             $http_upgrade;
proxy_set_header        Connection          $connection_upgrade;

proxy_cache off;
proxy_no_cache 1;
proxy_cache_bypass $http_pragma $http_authorization;

add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
add_header Pragma "no-cache" always;
add_header Expires "0" always;

proxy_connect_timeout   10s;
proxy_send_timeout      120s;
proxy_read_timeout      3600s;

proxy_buffering         off;
proxy_buffer_size       64k;
proxy_buffers           8 64k;

client_body_temp_path   /tmp/;
proxy_redirect          off;
