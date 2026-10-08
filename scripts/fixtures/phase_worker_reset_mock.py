#!/usr/bin/env python3
"""Control-only test worker: record snapshots while their blobs are alive."""
import json
import os
from pathlib import Path
import struct
import sys

while header := sys.stdin.buffer.read(4):
    size = struct.unpack('>I', header)[0]
    message = json.loads(sys.stdin.buffer.read(size))
    response = dict(v=1, id=message['id'], type=message['type'])
    if message['type'] == 'initialize':
        response.update(type='initialized', capabilities=[
            'asset-rpc-binary-read-v1', 'build-result-binary-v1',
            'shared-blocked-assets-v1', 'reset-overlay-blob-v1'])
    if message['type'] == 'reset_resolver' and message['overlay_blob'] is not None:
        blob = message['overlay_blob']
        data = Path(blob['path']).read_bytes()
        assert len(data) == blob['length']
        message['contents'] = {asset: list(data[value['offset']:value['offset'] + value['length']])
                               for asset, value in blob['index'].items()}
        if Path('fail-reset').exists():
            response['type'] = 'error'
    message['pid'] = os.getpid()
    fd = os.open('requests.jsonl', os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.write(fd, (json.dumps(message) + '\n').encode())
    os.close(fd)
    encoded = json.dumps(response).encode()
    sys.stdout.buffer.write(struct.pack('>I', len(encoded)) + encoded)
    sys.stdout.buffer.flush()
