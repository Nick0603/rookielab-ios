#!/usr/bin/env python3
"""上傳完的 build 處理好之後：寫「這版要測什麼」、加進外部測試群組、送 beta 審核（內部群組會自動拿到）。
用法：python3 ios/testflight-distribute.py <版本號> "<這版要測什麼>" [build 號]
build 號（testflight.sh 印的「封存（build …）」）給了就等那一個 build 出現並處理完；沒給就用最新上傳的
金鑰設定讀 ~/.appstoreconnect/env（ASC_KEY_ID、ASC_ISSUER_ID），需要 pip 的 PyJWT 與 cryptography。"""
import json, os, sys, time, urllib.request, urllib.error
import jwt

APP = '6829168144'
EXTERNAL = 'c9c1b668-b61d-468d-a97a-91f09f670337'
env = dict(l.split('=', 1) for l in open(os.path.expanduser('~/.appstoreconnect/env')).read().replace('export ', '').split() if '=' in l)
KID, ISS = env['ASC_KEY_ID'], env['ASC_ISSUER_ID']
KEY = open(os.path.expanduser(f'~/.appstoreconnect/private_keys/AuthKey_{KID}.p8')).read()

def call(method, path, body=None):
    tok = jwt.encode({'iss': ISS, 'iat': int(time.time()), 'exp': int(time.time()) + 1100, 'aud': 'appstoreconnect-v1'}, KEY, algorithm='ES256', headers={'kid': KID, 'typ': 'JWT'})
    req = urllib.request.Request('https://api.appstoreconnect.apple.com' + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req) as r:
            t = r.read()
            return json.loads(t) if t else {}
    except urllib.error.HTTPError as e:
        return {'_error': e.code, 'body': json.loads(e.read() or b'{}')}

def err(r):
    return '_error' in r and r['body'].get('errors', [{}])[0].get('detail')

version, notes = sys.argv[1], sys.argv[2]
want = sys.argv[3] if len(sys.argv) > 3 else None
for _ in range(60):
    q = f'/v1/builds?filter[app]={APP}&filter[preReleaseVersion.version]={version}&sort=-uploadedDate&limit=1'
    if want:
        q += f'&filter[version]={want}'
    d = call('GET', q).get('data', [])
    if d and d[0]['attributes']['processingState'] in ('VALID', 'INVALID', 'FAILED'):
        break
    time.sleep(60)
b = d[0]
print('build', b['attributes']['version'], b['attributes']['processingState'])
if b['attributes']['processingState'] != 'VALID':
    sys.exit(1)
B = b['id']
locs = call('GET', f'/v1/builds/{B}/betaBuildLocalizations')['data']
zh = [l for l in locs if l['attributes']['locale'] == 'zh-Hant']
r = (call('PATCH', f"/v1/betaBuildLocalizations/{zh[0]['id']}", {'data': {'type': 'betaBuildLocalizations', 'id': zh[0]['id'], 'attributes': {'whatsNew': notes}}}) if zh
     else call('POST', '/v1/betaBuildLocalizations', {'data': {'type': 'betaBuildLocalizations', 'attributes': {'locale': 'zh-Hant', 'whatsNew': notes}, 'relationships': {'build': {'data': {'type': 'builds', 'id': B}}}}}))
print('測試內容', err(r) or 'ok')
r = call('POST', f'/v1/betaGroups/{EXTERNAL}/relationships/builds', {'data': [{'type': 'builds', 'id': B}]})
print('外部群組', err(r) or 'ok')
r = call('POST', '/v1/betaAppReviewSubmissions', {'data': {'type': 'betaAppReviewSubmissions', 'relationships': {'build': {'data': {'type': 'builds', 'id': B}}}}})
print('beta 審核', err(r) or r['data']['attributes']['betaReviewState'])
