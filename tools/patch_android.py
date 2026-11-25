"""Patch the generated Android manifest: permissions, cleartext http (local network), Telugu app name."""
import pathlib, re, sys

p = pathlib.Path('android/app/src/main/AndroidManifest.xml')
s = p.read_text(encoding='utf-8')

perms = '''    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29"/>
    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
'''

if 'MANAGE_EXTERNAL_STORAGE' not in s:
    s = s.replace('<application', perms + '    <application', 1)

s = re.sub(r'android:label="[^"]*"', 'android:label="ఫోన్ మూవ్"', s, count=1)

if 'usesCleartextTraffic' not in s:
    s = s.replace('<application',
                  '<application android:usesCleartextTraffic="true" android:requestLegacyExternalStorage="true"', 1)

p.write_text(s, encoding='utf-8')
print(s)
assert 'MANAGE_EXTERNAL_STORAGE' in s and 'usesCleartextTraffic' in s
