#!/usr/bin/env python3
"""
Keep the TLS cert in sync across a multi-node fleet sharing one domain.

Runs on every node via cron (installed by aws/ec2_deploy.sh). Only node
PRIMARY_BALANCER_HOST runs certbot directly; every other node picks up its
cert from S3 here instead of running its own (doomed, since HTTP-01
validation would land on whichever node the load balancer picks).

Config comes from two files:
  /opt/api/var/django.conf (real Django settings, KEY = "value" format):
    AWS_KEY, AWS_SECRET, AWS_REGION   — already required for everything else
  /opt/api/var/ops.json (deploy/ops metadata, not Django settings — see
  aws/deploy.py's build_ops_json()):
    AWS_CERT_BUCKET                   — private S3 bucket for cert exchange
    LOAD_BALANCER_DOMAIN              — the shared TLS domain (cert directory name)
    PRIMARY_BALANCER_HOST             — hostname of the node that owns certbot

If ops.json is missing or any of these are unset (single-node deploys), this
script no-ops.
"""
import json
import os
import socket
import sys

import boto3


def read_conf(filepath):
    """Read /opt/api/var/django.conf's KEY = "value" format."""
    config = {}
    if not os.path.exists(filepath):
        return config
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                config[key.strip()] = value.strip().strip('"').strip("'")
    return config


def read_ops_json(filepath):
    if not os.path.exists(filepath):
        return {}
    with open(filepath) as f:
        return json.load(f)


def get_local_mtime(filepath):
    return int(os.path.getmtime(filepath)) if os.path.exists(filepath) else 0


def get_s3_mtime(s3, bucket, key):
    try:
        obj = s3.head_object(Bucket=bucket, Key=key)
        return int(obj['Metadata'].get('created', 0))
    except Exception:
        return 0


def upload(s3, bucket, key, filepath, mtime):
    s3.upload_file(filepath, bucket, key, ExtraArgs={'Metadata': {'created': str(mtime)}})


def download(s3, bucket, key, filepath):
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    s3.download_file(bucket, key, filepath)


def main():
    config = read_conf('/opt/api/var/django.conf')
    ops = read_ops_json('/opt/api/var/ops.json')

    required_conf = ['AWS_KEY', 'AWS_SECRET', 'AWS_REGION']
    required_ops = ['AWS_CERT_BUCKET', 'LOAD_BALANCER_DOMAIN', 'PRIMARY_BALANCER_HOST']
    if any(not config.get(k) for k in required_conf) or any(not ops.get(k) for k in required_ops):
        # Single-node deploys don't have ops.json at all — nothing to sync, exit quietly.
        return

    domain = ops['LOAD_BALANCER_DOMAIN']
    bucket = ops['AWS_CERT_BUCKET']
    primary_host = ops['PRIMARY_BALANCER_HOST']
    cert_dir = f'/etc/letsencrypt/live/{domain}'

    # fullchain.pem is the public cert (safe to store as-is); privkey.pem must
    # stay private end-to-end — the bucket must block public access and use
    # default encryption (both set by aws/deploy.py's setup_cert_bucket()).
    files = ['fullchain.pem', 'privkey.pem']

    s3 = boto3.client(
        's3',
        region_name=config['AWS_REGION'],
        aws_access_key_id=config['AWS_KEY'],
        aws_secret_access_key=config['AWS_SECRET'],
    )

    hostname = socket.gethostname()
    local_mtime = get_local_mtime(f'{cert_dir}/fullchain.pem')

    if hostname == primary_host:
        s3_mtime = get_s3_mtime(s3, bucket, f'/{domain}/fullchain.pem')
        if local_mtime > 0 and local_mtime > s3_mtime:
            for name in files:
                upload(s3, bucket, f'/{domain}/{name}', f'{cert_dir}/{name}', local_mtime)
    else:
        s3_mtime = get_s3_mtime(s3, bucket, f'/{domain}/fullchain.pem')
        if s3_mtime > local_mtime:
            for name in files:
                download(s3, bucket, f'/{domain}/{name}', f'{cert_dir}/{name}')
            os.system('sudo systemctl reload nginx.service')


if __name__ == '__main__':
    main()
