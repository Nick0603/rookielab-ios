#!/usr/bin/env python3
"""Sign static iOS policy bytes using a local Ed25519 key. Never prints private material.
Usage: python3 ios/update-policy.py sign policy.json output.json --key /private/path/key.pem
       python3 ios/update-policy.py verify output.json --public-key BASE64
       python3 ios/update-policy.py init --key /private/path/key.pem
Private keys belong outside the repository; provision the same key into protected CI if automated.
"""
import argparse, base64, json, os, time, re
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization
p=argparse.ArgumentParser();p.add_argument('action',choices=['init','draft','sign','verify']);p.add_argument('files',nargs='*');p.add_argument('--key');p.add_argument('--public-key');a=p.parse_args()
if a.action=='draft':
    current=json.loads(Path('public/app-config/ios-update-policy.json').read_text())
    policy=json.loads(base64.b64decode(current['payload']))
    policy['revision']+=1; policy['effectiveAt']=int(time.time())-30; policy['expiresAt']=policy['effectiveAt']+86400
    Path(a.files[0]).write_text(json.dumps(policy,ensure_ascii=False,indent=2)+'\n');print('Editable draft written; review channels and availability before signing')
elif a.action=='verify':
    e=json.loads(Path(a.files[0]).read_text());Ed25519PublicKey.from_public_bytes(base64.b64decode(a.public_key,validate=True)).verify(base64.b64decode(e['signature'],validate=True),base64.b64decode(e['payload'],validate=True));print('Signature valid')
else:
    path=Path(a.key).expanduser()
    if a.action=='init':
        path.parent.mkdir(parents=True,exist_ok=True)
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'wb') as f: f.write(Ed25519PrivateKey.generate().private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    key=serialization.load_pem_private_key(path.read_bytes(),password=None)
    public=base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)).decode()
    if a.action=='init': print(public)
    else:
        policy=json.loads(Path(a.files[0]).read_text())
        assert policy['schemaVersion']==1 and policy['bundleID']=='io.rookielab.app'
        assert 0 < policy['expiresAt']-policy['effectiveAt'] <= 86400
        assert policy['effectiveAt'] <= time.time() < policy['expiresAt']
        assert set(policy['channels'])=={'production','testflight'}
        current=json.loads(base64.b64decode(json.loads(Path('public/app-config/ios-update-policy.json').read_text())['payload']))
        assert policy['revision'] > current['revision'], 'Increase revision before publishing a policy change'
        for channel in policy['channels'].values():
            assert all(re.fullmatch(r'[0-9]{1,9}(?:\.[0-9]{1,9}){0,3}',channel[k]) for k in ['minimumVersion','recommendedVersion'])
            version=lambda value: tuple(map(int,value.split('.')))+(0,)*(4-len(value.split('.')))
            assert version(channel['minimumVersion']) <= version(channel['recommendedVersion'])
            assert channel['minimumBuild']>=0 and channel['recommendedBuild']>=0
            assert 18 <= channel['minimumOS'] <= channel['maximumOS']
        payload=json.dumps(policy,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
        envelope={'payload':base64.b64encode(payload).decode(),'signature':base64.b64encode(key.sign(payload)).decode()}
        Path(a.files[1]).write_text(json.dumps(envelope,indent=2)+'\n');print('Signed policy written')
